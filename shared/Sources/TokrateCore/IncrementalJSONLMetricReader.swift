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

    init(url: URL, startPosition: StartPosition = .beginning, isFinalRead: Bool = false) {
        self.url = url
        self.startPosition = startPosition
        self.isFinalRead = isFinalRead
        parser = Parser(sourceIdentity: url.standardizedFileURL.path)
        tailInitializationPending = if case .recentTail = startPosition { true } else { false }
        fileNumber = Self.currentFileNumber(url)
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
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let bytes = try handle.read(upToCount: count) ?? Data()
        offset += UInt64(bytes.count)
        bytesReadLastPoll = bytes.count
        isCaughtUp = offset >= size
        guard !bytes.isEmpty else { return [] }
        pending.append(bytes)

        var records: [TurnMetric] = []
        var lineStart = pending.startIndex
        while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
            let line = pending[lineStart..<newline]
            if !droppingLine, line.count <= Self.maximumLineBytes,
               let record = parser.consume(line: Data(line)) {
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
    private static var maximumPollBytes: Int { CodexSessionMonitor.maximumPollBytes }
    private static var maximumFiles: Int { 2_000 }
    private static var readerBatchBytes: Int { 65_536 }

    private struct WatchedFile {
        var live: IncrementalJSONLMetricReader<Parser>
        var archive: IncrementalJSONLMetricReader<Parser>?
        var modifiedAt: Date
        var liveServicedModification = Date.distantPast
        /// The `now` of the poll that positioned the live reader.
        var liveStartedAt: Date?
        var archiveIDsWhileLiveCatchesUp: Set<String> = []
    }

    private let root: URL
    private let liveSince: Date
    private let includesFile: @Sendable (URL) -> Bool
    private var files: [String: WatchedFile] = [:]
    private var lastDiscovery = Date.distantPast
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
                liveStartedAt: $0.liveStartedAt
            )
        })
    }

    init(
        root: URL,
        liveSince: Date = .now,
        includesFile: @escaping @Sendable (URL) -> Bool = { $0.pathExtension.lowercased() == "jsonl" }
    ) {
        self.root = root
        self.liveSince = liveSince
        self.includesFile = includesFile
    }

    func poll(now: Date = .now) throws -> MonitorUpdate {
        if now.timeIntervalSince(lastDiscovery) >= 10 || files.isEmpty {
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
        var byteBudget = Self.maximumPollBytes
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
                let recent = try file.live.poll(maxBytes: min(Self.readerBatchBytes, liveBudget), now: now)
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
                    let historical = try archive.poll(maxBytes: min(Self.readerBatchBytes, byteBudget), now: now)
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
                } catch { /* Retry this source file next time. */ }
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
                  modified >= now.addingTimeInterval(-MetricHistory.retention) else { continue }
            candidates.append((url, modified, values?.fileSize ?? 0))
        }
        candidates.sort { $0.modified > $1.modified }
        var seen = Set<String>()
        for candidate in candidates.prefix(Self.maximumFiles) {
            let key = candidate.url.standardizedFileURL.path
            seen.insert(key)
            if var file = files[key] {
                file.modifiedAt = candidate.modified
                files[key] = file
            } else {
                files[key] = WatchedFile(
                    live: IncrementalJSONLMetricReader(url: candidate.url, startPosition: .recentTail(maximumBytes: Self.recentTailBytes)),
                    archive: candidate.size > Self.recentTailBytes ? IncrementalJSONLMetricReader(url: candidate.url, isFinalRead: true) : nil,
                    modifiedAt: candidate.modified
                )
            }
        }
        files = files.filter { seen.contains($0.key) }
        watchedFileCount = files.count
    }
}
