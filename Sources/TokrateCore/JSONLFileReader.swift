import Foundation

/// Incrementally reads appended JSONL bytes, retaining only a bounded partial line.
public struct JSONLFileReader: Sendable {
    public static let maximumLineBytes = 1_048_576
    public static let defaultBatchBytes = 262_144

    public private(set) var bytesReadLastPoll = 0

    private let url: URL
    private var parser: CodexEventParser
    private var offset: UInt64 = 0
    private var pending = Data()
    private var fileNumber: UInt64?
    private var droppingOversizedLine = false

    public init(url: URL) {
        self.url = url
        parser = CodexEventParser(sourceIdentity: url.standardizedFileURL.path)
        fileNumber = Self.currentFileNumber(url)
    }

    /// Reads at most `maxBytes` from the current file. Call again to continue a large backlog.
    public mutating func poll(maxBytes: Int = defaultBatchBytes) throws -> [TurnMetric] {
        bytesReadLastPoll = 0
        guard maxBytes > 0 else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let currentSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let currentNumber = Self.fileNumber(from: attributes)
        if currentSize < offset || (fileNumber != nil && currentNumber != nil && fileNumber != currentNumber) {
            offset = 0
            pending.removeAll(keepingCapacity: true)
            droppingOversizedLine = false
            parser.reset(sourceIdentity: url.standardizedFileURL.path)
        }
        fileNumber = currentNumber
        guard currentSize > offset else { return [] }

        let count = Int(min(UInt64(maxBytes), currentSize - offset))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let bytes = try handle.read(upToCount: count) ?? Data()
        offset += UInt64(bytes.count)
        bytesReadLastPoll = bytes.count
        guard !bytes.isEmpty else { return [] }
        pending.append(bytes)

        var records: [TurnMetric] = []
        var lineStart = pending.startIndex
        while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
            let line = pending[lineStart..<newline]
            if !droppingOversizedLine, line.count <= Self.maximumLineBytes,
               let record = parser.consume(line: Data(line)) {
                records.append(record)
            }
            droppingOversizedLine = false
            lineStart = pending.index(after: newline)
        }
        if lineStart > pending.startIndex { pending.removeSubrange(pending.startIndex..<lineStart) }
        if pending.count > Self.maximumLineBytes {
            pending.removeAll(keepingCapacity: true)
            droppingOversizedLine = true
        }
        return records
    }

    /// Drops buffered state and rereads this path from byte zero on the next poll.
    public mutating func reset() {
        offset = 0
        pending.removeAll(keepingCapacity: true)
        droppingOversizedLine = false
        fileNumber = Self.currentFileNumber(url)
        parser.reset(sourceIdentity: url.standardizedFileURL.path)
    }

    private static func currentFileNumber(_ url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return fileNumber(from: attributes)
    }

    private static func fileNumber(from attributes: [FileAttributeKey: Any]) -> UInt64? {
        (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}
