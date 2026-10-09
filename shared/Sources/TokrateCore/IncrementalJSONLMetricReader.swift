import Foundation

protocol JSONLMetricParser: Sendable {
    init(sourceIdentity: String)
    mutating func consume(line: Data) -> TurnMetric?
    mutating func reset(sourceIdentity: String)
    mutating func reconcile(snapshot: Data) -> [TurnMetric]
    /// Called at the start of every poll, after any file replacement reset. `wasCaughtUp` is true when an
    /// earlier poll had already consumed the file to its end, so the lines read now are newly written.
    mutating func readWillBegin(wasCaughtUp: Bool)
    /// The session-level reasoning effort currently recorded beside the event log, if any.
    mutating func observeSessionEffort(_ effort: String?)
    /// Called when the reader starts at a recent tail offset inside the file rather than at byte 0.
    mutating func markStartedMidFile()
    /// True while a complete record sequence waits for proof that no further record belongs to it.
    var hasPendingWork: Bool { get }
    /// Called at the end of every poll in which the reader is caught up with its file. `isFinal` is
    /// true for archive reads, which close whatever they are holding at end of file.
    mutating func pollEnded(now: Date, isFinal: Bool) -> TurnMetric?
    /// Qualifying responses completed since the last call (see `ResponseSpeed`).
    mutating func drainCompletedResponses() -> [LiveResponse]
    /// Delegated-work lifecycle events since the last call (see `DelegationEvent`).
    mutating func drainDelegationEvents() -> [DelegationEvent]
}

extension JSONLMetricParser {
    mutating func reconcile(snapshot: Data) -> [TurnMetric] { [] }
    mutating func readWillBegin(wasCaughtUp: Bool) {}
    mutating func observeSessionEffort(_ effort: String?) {}
    mutating func markStartedMidFile() {}
    var hasPendingWork: Bool { false }
    mutating func pollEnded(now: Date, isFinal: Bool) -> TurnMetric? { nil }
    mutating func drainCompletedResponses() -> [LiveResponse] { [] }
    mutating func drainDelegationEvents() -> [DelegationEvent] { [] }
}

/// Incremental, bounded JSONL input for the additional local transcript formats.
/// Codex continues to use its existing reader and parser unchanged.
struct IncrementalJSONLMetricReader<Parser: JSONLMetricParser>: Sendable {
    enum StartPosition: Sendable {
        case beginning
        case recentTail(maximumBytes: Int)
        /// Continue after `offset` bytes an earlier run read in full (a checkpoint, always at a line
        /// boundary). Nothing is read until the file grows. The parser stays synchronised, unlike a
        /// recent tail: no archive read follows to recover the first turn after the checkpoint, and a file
        /// quiet for minutes is between turns. Claude Code records carry their own context, so there is
        /// no header to read.
        case resume(atOffset: UInt64)
    }

    static var maximumLineBytes: Int { JSONLFileReader.maximumLineBytes }
    private let url: URL
    private let startPosition: StartPosition
    /// Archive reads end at a known end of file, so nothing more can extend a pending record.
    private let isFinalRead: Bool
    private var parser: Parser
    private var offset: UInt64 = 0
    private var pending = Data()
    private var fileNumber: UInt64?
    private var droppingLine = false
    private var tailInitializationPending: Bool
    private(set) var bytesReadLastPoll = 0
    private(set) var isCaughtUp = false
    var hasPendingWork: Bool { parser.hasPendingWork }

    /// `makeParser` builds the parser from the file's standardized path; a source whose parser needs more
    /// than the path (Kimi Code's surface and agent scope) supplies it.
    init(
        url: URL, startPosition: StartPosition = .beginning, isFinalRead: Bool = false,
        makeParser: (String) -> Parser = { Parser(sourceIdentity: $0) }
    ) {
        self.url = url
        self.startPosition = startPosition
        self.isFinalRead = isFinalRead
        parser = makeParser(url.standardizedFileURL.path)
        tailInitializationPending = if case .recentTail = startPosition { true } else { false }
        fileNumber = Self.currentFileNumber(url)
        if case .resume(let resumeOffset) = startPosition {
            offset = resumeOffset
            isCaughtUp = true
        }
    }

    /// The file identity and offset a later run can resume from, once this reader has read the file to
    /// its end on a line boundary with no record held open; nil otherwise.
    var checkpointPosition: (fileNumber: UInt64, offset: UInt64)? {
        guard isCaughtUp, offset > 0, pending.isEmpty, !droppingLine, !parser.hasPendingWork,
              let fileNumber else { return nil }
        return (fileNumber, offset)
    }

    mutating func poll(maxBytes: Int, now: Date = .now) throws -> [TurnMetric] {
        bytesReadLastPoll = 0
        guard maxBytes > 0 else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let number = Self.fileNumber(from: attributes)
        if size < offset || (fileNumber != nil && number != nil && fileNumber != number) {
            resetForReplacement(size: size)
        }
        fileNumber = number

        if tailInitializationPending {
            if case .recentTail(let maximumBytes) = startPosition {
                let tail = UInt64(max(1, maximumBytes))
                offset = size > tail ? size - tail : 0
                // A tail can start in the middle of a record. Drop that first partial line.
                droppingLine = offset > 0
                if offset > 0 { parser.markStartedMidFile() }
            }
            tailInitializationPending = false
        }

        parser.readWillBegin(wasCaughtUp: isCaughtUp)
        guard size > offset else {
            isCaughtUp = true
            return parser.pollEnded(now: now, isFinal: isFinalRead).map { [$0] } ?? []
        }
        let count = Int(min(UInt64(maxBytes), size - offset))
        let handle = try RegularFile.open(url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let bytes = try handle.readDraining(upToCount: count)
        offset += UInt64(bytes.count)
        bytesReadLastPoll = bytes.count
        isCaughtUp = offset >= size
        guard !bytes.isEmpty else { return [] }
        pending.append(bytes)

        var records: [TurnMetric] = []
        var lineStart = pending.startIndex
        while let newline = pending.indexOfLineFeed(from: lineStart) {
            let line = pending[lineStart..<newline]
            if !droppingLine, line.count <= Self.maximumLineBytes,
               let record = autoreleasepool(invoking: { parser.consume(line: Data(line)) }) {
                records.append(record)
            }
            droppingLine = false
            lineStart = pending.index(after: newline)
        }
        if lineStart > pending.startIndex { pending.removeSubrange(pending.startIndex..<lineStart) }
        if pending.count > Self.maximumLineBytes {
            pending.removeAll(keepingCapacity: true)
            droppingLine = true
        }
        if isCaughtUp, let closed = parser.pollEnded(now: now, isFinal: isFinalRead) { records.append(closed) }
        return records
    }

    mutating func reconcile(snapshot: Data) -> [TurnMetric] {
        parser.reconcile(snapshot: snapshot)
    }

    mutating func observeSessionEffort(_ effort: String?) {
        parser.observeSessionEffort(effort)
    }

    mutating func drainResponses() -> [LiveResponse] { parser.drainCompletedResponses() }

    mutating func drainDelegation() -> [DelegationEvent] { parser.drainDelegationEvents() }

    private mutating func resetForReplacement(size: UInt64) {
        offset = 0
        pending.removeAll(keepingCapacity: true)
        droppingLine = false
        parser.reset(sourceIdentity: url.standardizedFileURL.path)
        if case .recentTail = startPosition {
            tailInitializationPending = true
        } else {
            tailInitializationPending = false
        }
        isCaughtUp = false
        _ = size
    }

    private static func currentFileNumber(_ url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return fileNumber(from: attributes)
    }

    private static func fileNumber(from attributes: [FileAttributeKey: Any]) -> UInt64? {
        (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}

/// Applies the same live-tail/archive fairness and byte limits as Codex monitoring.
actor JSONLSourceSessionMonitor<Parser: JSONLMetricParser> {
    private static var recentTailBytes: Int { CodexSessionMonitor.recentTailBytes }
    private static var discoveryInterval: TimeInterval { CodexSessionMonitor.discoveryInterval }

    private struct WatchedFile {
        var live: IncrementalJSONLMetricReader<Parser>
        var archive: IncrementalJSONLMetricReader<Parser>?
        var modifiedAt: Date
        var liveServicedModification = Date.distantPast
        /// The `now` of the poll that positioned the live reader.
        var liveStartedAt: Date?
        var archiveIDsWhileLiveCatchesUp: Set<String> = []
        /// The modification time of the checkpoint this file was resumed from.
        var skippedThrough: Date?
    }

    private let root: URL
    private let scope: MonitorScope
    private let liveSince: Date
    private let includesFile: @Sendable (URL) -> Bool
    private let makeParser: @Sendable (String) -> Parser
    private let versionKey: String
    private let resumable: [String: SourceFileCheckpoint]
    private var files: [String: WatchedFile] = [:]
    private var lastDiscovery = Date.distantPast
    private var needsDiscovery = false
    private var nextArchiveIndex = 0
    private(set) var rootIsAvailable = false
    private(set) var watchedFileCount = 0

    /// The files that still have history to read: an archive reader in progress, a live reader short of
    /// its file's end, or a modification not read yet.
    var delegationBacklog: DelegationBacklog {
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

    /// `versionKey` is the parser and metric version of the records this monitor reads: a checkpoint
    /// written under another one is ignored. `checkpoints` are the files an earlier run read to their
    /// end, whose records are already in the history.
    init(
        root: URL,
        liveSince: Date = .now,
        versionKey: String,
        checkpoints: [SourceFileCheckpoint] = [],
        scope: MonitorScope = .live,
        includesFile: @escaping @Sendable (URL) -> Bool = { $0.pathExtension.lowercased() == "jsonl" },
        makeParser: @escaping @Sendable (String) -> Parser = { Parser(sourceIdentity: $0) }
    ) {
        self.root = root
        self.scope = scope
        self.liveSince = liveSince
        self.versionKey = versionKey
        resumable = Dictionary(checkpoints.map { ($0.pathDigest, $0) }, uniquingKeysWith: { _, last in last })
        self.includesFile = includesFile
        self.makeParser = makeParser
    }

    func poll(now: Date = .now) throws -> MonitorUpdate {
        if needsDiscovery || now.timeIntervalSince(lastDiscovery) >= Self.discoveryInterval || files.isEmpty {
            // Cleared first so a failing enumeration is retried by the safety net, not on every poll.
            needsDiscovery = false
            try discoverFiles(now: now)
            lastDiscovery = now
        }
        guard rootIsAvailable else { return MonitorUpdate() }

        var result: [TurnMetric] = []
        var responses: [String: LiveResponse] = [:]
        var delegation: [DelegationEvent] = []
        func collect(_ completed: [LiveResponse]) {
            for response in completed where response.completedAt >= liveSince { responses[response.id] = response }
        }
        var byteBudget = scope.maximumPollBytes
        var liveBudget = byteBudget * 3 / 4
        let liveKeys = files.keys.filter { key in
            guard let file = files[key] else { return false }
            return !file.live.isCaughtUp || file.modifiedAt > file.liveServicedModification || file.live.hasPendingWork
        }.sorted { left, right in
            let a = files[left]!.modifiedAt, b = files[right]!.modifiedAt
            return a == b ? left < right : a > b
        }
        for key in liveKeys.prefix(24) {
            guard liveBudget > 0, var file = files[key] else { break }
            do {
                let recent = try file.live.poll(maxBytes: min(scope.readerBatchBytes, liveBudget), now: now)
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
                files[key] = file
            } catch {
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
                    let historical = try archive.poll(maxBytes: min(scope.readerBatchBytes, byteBudget), now: now)
                    collect(archive.drainResponses())
                    delegation += archive.drainDelegation()
                    result += historical
                    if !file.live.isCaughtUp {
                        for record in historical where file.archiveIDsWhileLiveCatchesUp.count < 8_192 {
                            file.archiveIDsWhileLiveCatchesUp.insert(record.id)
                        }
                    }
                    byteBudget -= archive.bytesReadLastPoll
                    file.archive = archive.isCaughtUp ? nil : archive
                    files[key] = file
                } catch { if error.isMissingFile { needsDiscovery = true } /* Retry this source file next time. */ }
                processed += 1
            }
            nextArchiveIndex = (nextArchiveIndex + processed) % archiveKeys.count
        }

        var unique: [String: TurnMetric] = [:]
        for record in result { unique[record.id] = record }
        var update = MonitorUpdate(
            metrics: unique.values.sorted { $0.completedAt > $1.completedAt },
            responses: responses.values.sorted { $0.completedAt > $1.completedAt }
        )
        update.delegation = delegation
        return update
    }

    /// Marks what a folder watcher reported so the next poll reads it: a changed known file is serviced
    /// again, and a new file this monitor includes or a lost event triggers discovery. Returns whether
    /// anything is now pending.
    @discardableResult
    func noteChanges(_ change: SessionFolderChange) -> Bool {
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
            } else if includesFile(URL(fileURLWithPath: path)), SessionFolderChange.isDiscoverable(path, under: root),
                      SessionFolderChange.modificationDate(ofRegularFileAt: path) != nil {
                needsDiscovery = true
                noted = true
            }
        }
        return noted
    }

    /// The files read to their end, whose records are all in the history, for a later run to skip; nil
    /// before the first discovery, when the previous set stays valid. The caller holds this back while
    /// a primary turn awaits its delegated total.
    func checkpoints() -> [SourceFileCheckpoint]? {
        guard rootIsAvailable else { return nil }
        return files.compactMap { path, file in
            guard file.archive == nil, file.live.isCaughtUp, file.liveServicedModification >= file.modifiedAt,
                  let position = file.live.checkpointPosition else { return nil }
            return SourceFileCheckpoint(
                pathDigest: SourceFileCheckpoint.digest(ofPath: path), fileNumber: position.fileNumber, size: position.offset,
                modifiedAt: file.modifiedAt, versionKey: versionKey
            )
        }.sorted { $0.pathDigest < $1.pathDigest }
    }

    /// `now` while any reader has bytes left to read, holds a record sequence open or discovery is due;
    /// nil when only a new write can make a poll useful.
    func nextPollDeadline(now: Date) -> Date? {
        let hasWork = needsDiscovery || files.values.contains {
            !$0.live.isCaughtUp || $0.modifiedAt > $0.liveServicedModification || $0.live.hasPendingWork || $0.archive != nil
        }
        return hasWork ? now : nil
    }

    private func discoverFiles(now: Date) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            rootIsAvailable = false
            files.removeAll(keepingCapacity: false)
            watchedFileCount = 0
            return
        }
        rootIsAvailable = true
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw CocoaError(.fileReadUnknown) }
        var candidates: [(url: URL, modified: Date, size: Int)] = []
        for case let url as URL in enumerator {
            guard includesFile(url) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate,
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
                url: candidate.url, size: candidate.size, modifiedAt: candidate.modified, versionKey: versionKey, now: now
            ) {
                // Read to its end by an earlier run and unchanged since: caught up, nothing to replay.
                files[key] = WatchedFile(
                    live: IncrementalJSONLMetricReader(url: candidate.url, startPosition: .resume(atOffset: offset), makeParser: makeParser),
                    archive: nil,
                    modifiedAt: candidate.modified,
                    liveServicedModification: candidate.modified,
                    skippedThrough: candidate.modified
                )
            } else if scope.replaysFromStart {
                // One reader over the whole file. A file quiet long enough is finished, so its open record
                // sequence closes at the end like an archive read; a file still being written stays open.
                let isQuiet = now.timeIntervalSince(candidate.modified) >= SourceFileCheckpoint.minimumQuietSeconds
                files[key] = WatchedFile(
                    live: IncrementalJSONLMetricReader(url: candidate.url, isFinalRead: isQuiet, makeParser: makeParser),
                    archive: nil,
                    modifiedAt: candidate.modified
                )
            } else {
                files[key] = WatchedFile(
                    live: IncrementalJSONLMetricReader(
                        url: candidate.url, startPosition: .recentTail(maximumBytes: Self.recentTailBytes), makeParser: makeParser
                    ),
                    archive: candidate.size > Self.recentTailBytes
                        ? IncrementalJSONLMetricReader(url: candidate.url, isFinalRead: true, makeParser: makeParser) : nil,
                    modifiedAt: candidate.modified
                )
            }
        }
        files = files.filter { seen.contains($0.key) }
        watchedFileCount = files.count
    }
}
