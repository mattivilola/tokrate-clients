import Foundation

/// Recent appended events have their own cursor; historical replay cannot hold them back.
///
/// Sessions spawned by a primary session (`thread_spawn` children) are read in full as delegated
/// work. The monitor attributes their output tokens to the primary turn of the same root session
/// that started them (see `DelegationAttributor`): a primary turn is emitted at once and re-emitted
/// under the same id once its delegated output tokens are final.
///
/// A file that a checkpoint from an earlier run describes exactly is not read again: it has no archive
/// reader and its live reader resumes at the end of the file (see `SourceFileCheckpoint`).
public actor CodexSessionMonitor {
    public static let recentTailBytes = 262_144
    public static let maximumPollBytes = 1_048_576
    /// Safety net for a folder watcher that missed a change; `noteChanges` normally triggers discovery.
    static let discoveryInterval: TimeInterval = 300
    private static let versionKey = SourceFileCheckpoint.versionKey(
        parser: TurnMetric.codexParserVersion, metric: TurnMetric.codexMetricVersion
    )

    private struct WatchedFile {
        var live: JSONLFileReader
        var archive: JSONLFileReader?
        var modifiedAt: Date
        var liveServicedModification = Date.distantPast
        /// The `now` of the poll that positioned the live reader.
        var liveStartedAt: Date?
        var archiveIDsWhileLiveCatchesUp: Set<String> = []
        /// The modification time of the checkpoint this file was resumed from.
        var skippedThrough: Date?
    }
    public private(set) var bytesReadLastPoll = 0
    private let root: URL
    private var files: [String: WatchedFile] = [:]
    private var lastDiscovery = Date.distantPast
    private var needsDiscovery = false
    private var nextArchiveIndex = 0
    private var attributor: DelegationAttributor

    private let scope: MonitorScope
    private let liveSince: Date
    private let resumable: [String: SourceFileCheckpoint]

    /// `liveSince` is the moment from which completed responses count as live; earlier responses are
    /// history and never reach the live stream. `checkpoints` are the files an earlier run read to
    /// their end, whose records are already in the history.
    public init(root: URL, liveSince: Date = .now, checkpoints: [SourceFileCheckpoint] = [], scope: MonitorScope = .live) {
        self.root = root
        self.scope = scope
        attributor = DelegationAttributor(scope: scope)
        self.liveSince = liveSince
        resumable = Dictionary(checkpoints.map { ($0.pathDigest, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func poll(now: Date = .now) throws -> MonitorUpdate {
        bytesReadLastPoll = 0
        var responses: [String: LiveResponse] = [:]
        var delegation: [DelegationEvent] = []
        func collect(_ completed: [LiveResponse]) {
            for response in completed where response.completedAt >= liveSince { responses[response.id] = response }
        }
        if needsDiscovery || now.timeIntervalSince(lastDiscovery) >= Self.discoveryInterval || files.isEmpty {
            // Cleared first so a failing enumeration is retried by the safety net, not on every poll.
            needsDiscovery = false
            try discoverFiles(now: now)
            lastDiscovery = now
        }
        var result: [TurnMetric] = []
        var byteBudget = scope.maximumPollBytes
        // Reserve one quarter for archive progress even when recent files are busy.
        var liveBudget = byteBudget * 3 / 4
        let liveKeys = files.keys.filter { key in
            guard let file = files[key] else { return false }
            return !file.live.isCaughtUp || file.modifiedAt > file.liveServicedModification
        }.sorted { left, right in
            let a = files[left]!.modifiedAt, b = files[right]!.modifiedAt
            return a == b ? left < right : a > b
        }
        for key in liveKeys.prefix(24) {
            guard liveBudget > 0, var file = files[key] else { break }
            do {
                let recent = try file.live.poll(maxBytes: min(scope.readerBatchBytes, liveBudget))
                if file.liveStartedAt == nil { file.liveStartedAt = now }
                collect(file.live.drainResponses())
                delegation += file.live.drainDelegation()
                result += recent.filter { !file.archiveIDsWhileLiveCatchesUp.contains($0.id) }
                let consumed = file.live.bytesReadLastPoll
                liveBudget -= consumed
                byteBudget -= consumed
                if file.live.isCaughtUp {
                    file.liveServicedModification = file.modifiedAt
                    file.archiveIDsWhileLiveCatchesUp.removeAll(keepingCapacity: false)
                }
                // The live reader of a spawned child reads it in full, so no archive pass is needed.
                if file.live.isSkippedSession || file.live.isDelegatedWork { file.archive = nil }
                files[key] = file
            } catch {
                // Retry changed/new files on the next pass; one inaccessible file cannot stop others.
                // A vanished file is retried by no one: discovery prunes it.
                if error.isMissingFile { needsDiscovery = true }
                files[key] = file
            }
        }

        let archiveKeys = files.keys.filter { files[$0]?.archive != nil }.sorted()
        if !archiveKeys.isEmpty {
            var processed = 0
            for step in 0..<min(24, archiveKeys.count) {
                guard byteBudget > 0 else { break }
                let key = archiveKeys[(nextArchiveIndex + step) % archiveKeys.count]
                guard var file = files[key], var archive = file.archive else { continue }
                do {
                    let historical = try archive.poll(maxBytes: min(scope.readerBatchBytes, byteBudget))
                    collect(archive.drainResponses())
                    delegation += archive.drainDelegation()
                    result += historical
                    if !file.live.isCaughtUp {
                        for record in historical where file.archiveIDsWhileLiveCatchesUp.count < 8192 {
                            file.archiveIDsWhileLiveCatchesUp.insert(record.id)
                        }
                    }
                    byteBudget -= archive.bytesReadLastPoll
                    file.archive = archive.isCaughtUp || archive.isSkippedSession ? nil : archive
                    files[key] = file
                } catch { if error.isMissingFile { needsDiscovery = true } /* Keep the cursor for a later retry. */ }
                processed += 1
            }
            // Advance by readers actually attempted, not the nominal batch size.
            nextArchiveIndex = (nextArchiveIndex + processed) % archiveKeys.count
        }
        // Both cursors use the same local digest. Complete archive context wins on overlap,
        // including an unknown model when the full turn contains conflicting model metadata.
        var unique: [String: TurnMetric] = [:]
        for record in result {
            unique[record.id] = record
        }
        bytesReadLastPoll = scope.maximumPollBytes - byteBudget
        let metrics = unique.values.sorted { $0.completedAt > $1.completedAt }
        attributor.ingest(events: delegation, metrics: metrics)
        let finals = attributor.finalize(now: now, backlog: delegationBacklog)
        return MonitorUpdate(
            metrics: DelegationAttributor.merging(metrics, finals: finals),
            responses: responses.values.sorted { $0.completedAt > $1.completedAt }
        )
    }

    /// Marks what a folder watcher reported so the next poll reads it: a changed known file is serviced
    /// again, and a new file or a lost event triggers discovery. Returns whether anything is now pending.
    @discardableResult
    public func noteChanges(_ change: SessionFolderChange) -> Bool {
        var noted = change.mustRescan
        if change.mustRescan { needsDiscovery = true }
        for path in change.paths {
            if var file = files[path] {
                if let modified = SessionFolderChange.modificationDate(ofRegularFileAt: path) {
                    file.modifiedAt = modified
                    file.liveServicedModification = .distantPast
                    files[path] = file
                } else {
                    needsDiscovery = true
                }
                noted = true
            } else if URL(fileURLWithPath: path).pathExtension.lowercased() == "jsonl", SessionFolderChange.isDiscoverable(path, under: root),
                      SessionFolderChange.modificationDate(ofRegularFileAt: path) != nil {
                needsDiscovery = true
                noted = true
            }
        }
        return noted
    }

    /// The files read to their end, whose records are all in the history, for a later run to skip; nil
    /// while that is not known and the previous set stays valid: before the first discovery, and while
    /// a primary turn awaits its delegated total (it is not final, and skipping its file would leave
    /// it so).
    public func checkpoints() -> [SourceFileCheckpoint]? {
        guard lastDiscovery != .distantPast, !attributor.hasPending else { return nil }
        return files.compactMap { path, file in
            guard file.archive == nil, file.live.isCaughtUp, file.liveServicedModification >= file.modifiedAt,
                  let position = file.live.checkpointPosition else { return nil }
            return SourceFileCheckpoint(
                pathDigest: SourceFileCheckpoint.digest(ofPath: path), fileNumber: position.fileNumber, size: position.offset,
                modifiedAt: file.modifiedAt, versionKey: Self.versionKey
            )
        }.sorted { $0.pathDigest < $1.pathDigest }
    }

    /// When the monitor needs to poll again if nothing else changes: `now` while any reader has bytes
    /// left to read or discovery is due, else the earliest delegation transition, else nil.
    public func nextPollDeadline(now: Date) -> Date? {
        let hasWork = needsDiscovery || files.values.contains {
            !$0.live.isCaughtUp || $0.modifiedAt > $0.liveServicedModification || $0.archive != nil
        }
        return hasWork ? now : attributor.nextDeadline(now: now)
    }

    /// The files that still have history to read: an archive reader in progress, a live reader short of
    /// its file's end, or a modification not read yet.
    private var delegationBacklog: DelegationBacklog {
        DelegationBacklog(files: files.values.map {
            DelegationSourceFile(
                modifiedAt: $0.modifiedAt,
                livePending: !$0.live.isCaughtUp || $0.modifiedAt > $0.liveServicedModification,
                archivePending: $0.archive != nil,
                liveStartedAt: $0.liveStartedAt,
                skippedThrough: $0.skippedThrough
            )
        })
    }

    private func discoverFiles(now: Date) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw CocoaError(.fileReadUnknown) }
        var candidates: [(url: URL, modified: Date, size: Int)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate,
                  modified >= now.addingTimeInterval(-scope.retention) else { continue }
            candidates.append((url, modified, values?.fileSize ?? 0))
        }
        candidates.sort { $0.modified > $1.modified }
        var seen = Set<String>()
        for candidate in candidates.prefix(scope.maximumFiles) {
            let key = candidate.url.standardizedFileURL.path
            seen.insert(key)
            if var file = files[key] {
                file.modifiedAt = candidate.modified
                files[key] = file
            } else if let offset = resumable[SourceFileCheckpoint.digest(ofPath: key)]?.resumeOffset(
                url: candidate.url, size: candidate.size, modifiedAt: candidate.modified, versionKey: Self.versionKey, now: now
            ) {
                // Read to its end by an earlier run and unchanged since: caught up, nothing to replay.
                files[key] = WatchedFile(
                    live: JSONLFileReader(url: candidate.url, startPosition: .resume(atOffset: offset)),
                    archive: nil,
                    modifiedAt: candidate.modified,
                    liveServicedModification: candidate.modified,
                    skippedThrough: candidate.modified
                )
            } else if scope.replaysFromStart {
                files[key] = WatchedFile(live: JSONLFileReader(url: candidate.url), archive: nil, modifiedAt: candidate.modified)
            } else {
                files[key] = WatchedFile(
                    live: JSONLFileReader(url: candidate.url, startPosition: .recentTail(maximumBytes: Self.recentTailBytes)),
                    archive: candidate.size > Self.recentTailBytes ? JSONLFileReader(url: candidate.url) : nil,
                    modifiedAt: candidate.modified
                )
            }
        }
        files = files.filter { seen.contains($0.key) }
    }
}
