import Foundation

/// Recent appended events have their own cursor; historical replay cannot hold them back.
public actor CodexSessionMonitor {
    public static let recentTailBytes = 262_144
    public static let maximumPollBytes = 1_048_576
    private static let maximumFiles = 2_000
    private static let readerBatchBytes = 65_536

    private struct WatchedFile {
        var live: JSONLFileReader
        var archive: JSONLFileReader?
        var modifiedAt: Date
        var liveServicedModification = Date.distantPast
        var archiveIDsWhileLiveCatchesUp: Set<String> = []
    }
    public private(set) var bytesReadLastPoll = 0
    private let root: URL
    private var files: [String: WatchedFile] = [:]
    private var lastDiscovery = Date.distantPast
    private var nextArchiveIndex = 0

    public init(root: URL) { self.root = root }

    public func poll(now: Date = .now) throws -> [TurnMetric] {
        bytesReadLastPoll = 0
        if now.timeIntervalSince(lastDiscovery) >= 10 || files.isEmpty {
            try discoverFiles(now: now)
            lastDiscovery = now
        }
        var result: [TurnMetric] = []
        var byteBudget = Self.maximumPollBytes
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
                let recent = try file.live.poll(maxBytes: min(Self.readerBatchBytes, liveBudget))
                result += recent.filter { !file.archiveIDsWhileLiveCatchesUp.contains($0.id) }
                let consumed = file.live.bytesReadLastPoll
                liveBudget -= consumed
                byteBudget -= consumed
                if file.live.isCaughtUp {
                    file.liveServicedModification = file.modifiedAt
                    file.archiveIDsWhileLiveCatchesUp.removeAll(keepingCapacity: false)
                }
                if file.live.excludesSessionFromMetrics { file.archive = nil }
                files[key] = file
            } catch {
                // Retry changed/new files on the next pass; one inaccessible file cannot stop others.
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
                    let historical = try archive.poll(maxBytes: min(Self.readerBatchBytes, byteBudget))
                    result += historical
                    if !file.live.isCaughtUp {
                        for record in historical where file.archiveIDsWhileLiveCatchesUp.count < 8192 {
                            file.archiveIDsWhileLiveCatchesUp.insert(record.id)
                        }
                    }
                    byteBudget -= archive.bytesReadLastPoll
                    file.archive = archive.isCaughtUp || archive.excludesSessionFromMetrics ? nil : archive
                    files[key] = file
                } catch { /* Keep the cursor for a later retry. */ }
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
        bytesReadLastPoll = Self.maximumPollBytes - byteBudget
        return unique.values.sorted { $0.completedAt > $1.completedAt }
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
                    live: JSONLFileReader(url: candidate.url, startPosition: .recentTail(maximumBytes: Self.recentTailBytes)),
                    archive: candidate.size > Self.recentTailBytes ? JSONLFileReader(url: candidate.url) : nil,
                    modifiedAt: candidate.modified
                )
            }
        }
        files = files.filter { seen.contains($0.key) }
    }
}
