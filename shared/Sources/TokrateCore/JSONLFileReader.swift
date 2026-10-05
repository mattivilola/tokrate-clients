import Foundation

/// Incrementally reads appended JSONL bytes, retaining only a bounded partial line.
public struct JSONLFileReader: Sendable {
    public static let maximumLineBytes = 1_048_576
    public static let defaultBatchBytes = 262_144

    public enum StartPosition: Sendable {
        case beginning
        /// Seed the first session metadata line, then start at a complete line near EOF.
        case recentTail(maximumBytes: Int)
    }

    public private(set) var bytesReadLastPoll = 0
    public private(set) var isCaughtUp = false
    /// The session is an agent session that is not delegated work: nothing in it is read.
    var isSkippedSession: Bool { parser.isSkippedSession }
    /// The session is a spawned child, read in full for its delegated work items only.
    var isDelegatedWork: Bool { parser.isDelegatedWork }
    private enum TailStartup: Sendable { case header, alignment, unavailable }
    private let tailByteLimit: Int?
    private var tailStartup: TailStartup?

    private let url: URL
    private var parser: CodexEventParser
    private var offset: UInt64 = 0
    private var pending = Data()
    private var fileNumber: UInt64?
    private var droppingOversizedLine = false

    public init(url: URL, startPosition: StartPosition = .beginning) {
        self.url = url
        switch startPosition {
        case .beginning:
            tailByteLimit = nil
            tailStartup = nil
        case .recentTail(let maximumBytes):
            tailByteLimit = max(1, maximumBytes)
            tailStartup = .header
        }
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
            tailStartup = tailByteLimit == nil ? nil : .header
            isCaughtUp = false
        }
        fileNumber = currentNumber
        if parser.isSkippedSession {
            offset = currentSize
            isCaughtUp = true
            return []
        }
        if tailStartup == .unavailable { isCaughtUp = true; return [] }
        guard currentSize > offset else {
            // An empty file has no history to wait for, whatever its startup phase.
            isCaughtUp = tailStartup == nil || currentSize == 0
            return []
        }
        if tailStartup == .header {
            try prepareRecentTail(currentSize: currentSize, maxBytes: maxBytes)
            return []
        }
        var readBudget = maxBytes
        if tailStartup == .alignment {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset - 1)
            let previous = try handle.read(upToCount: 1) ?? Data()
            bytesReadLastPoll += previous.count
            readBudget -= previous.count
            droppingOversizedLine = previous.first != 0x0A
            tailStartup = nil
        }
        guard readBudget > 0 else { return [] }

        let count = Int(min(UInt64(readBudget), currentSize - offset))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let bytes = try handle.read(upToCount: count) ?? Data()
        offset += UInt64(bytes.count)
        bytesReadLastPoll += bytes.count
        isCaughtUp = offset >= currentSize
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

    /// Reads only a bounded first line before seeking; no turn state is seeded from history.
    private mutating func prepareRecentTail(currentSize: UInt64, maxBytes: Int) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let bytes = try handle.read(upToCount: Int(min(UInt64(maxBytes), currentSize - offset))) ?? Data()
        offset += UInt64(bytes.count)
        bytesReadLastPoll = bytes.count
        pending.append(bytes)
        guard let newline = pending.firstIndex(of: 0x0A) else {
            if pending.count > Self.maximumLineBytes {
                pending.removeAll(keepingCapacity: false)
                tailStartup = .unavailable
                isCaughtUp = true
            }
            return
        }
        let line = Data(pending[..<newline])
        let headerEnd = offset - UInt64(pending.distance(from: pending.index(after: newline), to: pending.endIndex))
        pending.removeAll(keepingCapacity: false)
        guard line.count <= Self.maximumLineBytes,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "session_meta" else {
            // Fail closed when provenance cannot be read. The archive lane can still parse normally.
            tailStartup = .unavailable
            isCaughtUp = true
            return
        }
        _ = parser.consume(line: line)
        if parser.isSkippedSession {
            offset = currentSize
            tailStartup = nil
            isCaughtUp = true
            return
        }
        // Delegated work is read from its first line: a turn whose start is missed is not counted.
        if parser.isDelegatedWork {
            offset = headerEnd
            tailStartup = nil
            isCaughtUp = offset >= currentSize
            return
        }
        let tailStart = currentSize > UInt64(tailByteLimit ?? 0) ? currentSize - UInt64(tailByteLimit ?? 0) : 0
        offset = max(headerEnd, tailStart)
        tailStartup = offset > headerEnd ? .alignment : nil
        isCaughtUp = tailStartup == nil && offset >= currentSize
    }

    /// Qualifying responses completed since the last call.
    public mutating func drainResponses() -> [LiveResponse] { parser.drainCompletedResponses() }

    /// Delegated-work events since the last call.
    mutating func drainDelegation() -> [DelegationEvent] { parser.drainDelegationEvents() }

    /// Drops buffered state and restores the configured beginning/tail start position.
    public mutating func reset() {
        offset = 0
        pending.removeAll(keepingCapacity: true)
        droppingOversizedLine = false
        fileNumber = Self.currentFileNumber(url)
        parser.reset(sourceIdentity: url.standardizedFileURL.path)
        tailStartup = tailByteLimit == nil ? nil : .header
        isCaughtUp = false
        bytesReadLastPoll = 0
    }

    private static func currentFileNumber(_ url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return fileNumber(from: attributes)
    }

    private static func fileNumber(from attributes: [FileAttributeKey: Any]) -> UInt64? {
        (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}
