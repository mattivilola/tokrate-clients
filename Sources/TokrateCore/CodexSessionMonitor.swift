import Foundation

/// Scans a Codex sessions directory for new JSONL files and incrementally reads a bounded batch.
public actor CodexSessionMonitor {
    private let root: URL
    private var readers: [String: JSONLFileReader] = [:]
    private var lastDiscovery = Date.distantPast
    private var nextReaderIndex = 0

    public init(root: URL) {
        self.root = root
    }

    public func poll(now: Date = .now) throws -> [TurnMetric] {
        if now.timeIntervalSince(lastDiscovery) >= 10 || readers.isEmpty {
            try discoverFiles(now: now)
            lastDiscovery = now
        }
        let keys = readers.keys.sorted()
        guard !keys.isEmpty else { return [] }
        var result: [TurnMetric] = []
        var byteBudget = 1_048_576
        let fileBudget = min(20, keys.count)
        for step in 0..<fileBudget {
            let index = (nextReaderIndex + step) % keys.count
            let key = keys[index]
            guard var reader = readers[key] else { continue }
            let batchSize = min(65_536, byteBudget)
            do {
                result.append(contentsOf: try reader.poll(maxBytes: batchSize))
                readers[key] = reader
                byteBudget -= batchSize
            } catch {
                readers.removeValue(forKey: key)
            }
            if byteBudget <= 0 { break }
        }
        nextReaderIndex = (nextReaderIndex + fileBudget) % keys.count
        return result
    }

    private func discoverFiles(now: Date) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw CocoaError(.fileReadUnknown) }

        var seen = Set<String>()
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true, (values?.contentModificationDate ?? .distantPast) >= now.addingTimeInterval(-MetricHistory.retention) else { continue }
            let key = url.standardizedFileURL.path
            seen.insert(key)
            if readers[key] == nil, readers.count < 2_000 {
                readers[key] = JSONLFileReader(url: url)
            }
        }
        readers = readers.filter { seen.contains($0.key) }
    }
}
