import Foundation

/// Incrementally reads appended JSONL bytes, retaining only a bounded partial line.
public struct JSONLFileReader: Sendable {
    public static let maximumLineBytes = 1_048_576
    public static let defaultBatchBytes = 262_144

    public enum StartPosition: Sendable {
        case beginning
        /// Seed the first session metadata line, then start at a complete line near EOF.
        case recentTail(maximumBytes: Int)
        /// Continue after `offset` bytes an earlier run read in full (a checkpoint, always at a line
        /// boundary). Nothing is read until the file grows, and then the first line is read once so the
        /// appended records resolve their session as they do after a recent-tail start.
        case resume(atOffset: UInt64)
    }

    public private(set) var bytesReadLastPoll = 0
    public private(set) var isCaughtUp = false
    /// The session is an agent session that is not delegated work: nothing in it is read.
    var isSkippedSession: Bool { parser.isSkippedSession }
    /// The session is a spawned child, read in full for its delegated work items only.
    var isDelegatedWork: Bool { parser.isDelegatedWork }
    private enum TailStartup: Sendable { case header, alignment, unavailable, context }
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
        case .resume(let resumeOffset):
            tailByteLimit = nil
            tailStartup = .context
            offset = resumeOffset
            isCaughtUp = true
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
            isCaughtUp = tailStartup == nil || tailStartup == .context || currentSize == 0
            return []
        }
        if tailStartup == .header {
            try prepareRecentTail(currentSize: currentSize, maxBytes: maxBytes)
            return []
        }
        var readBudget = maxBytes
        if tailStartup == .context {
            isCaughtUp = false
            let headerBytes = try restoreHeader(currentSize: currentSize)
            bytesReadLastPoll += headerBytes
            readBudget -= headerBytes
            // A header that cannot be used (or a skipped session) leaves nothing to read.
            if isCaughtUp { return [] }
        }
        if tailStartup == .alignment {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset - 1)
            let previous = try handle.readDraining(upToCount: 1)
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
        let bytes = try handle.readDraining(upToCount: count)
        offset += UInt64(bytes.count)
        bytesReadLastPoll += bytes.count
        isCaughtUp = offset >= currentSize
        guard !bytes.isEmpty else { return [] }
        pending.append(bytes)

        var records: [TurnMetric] = []
        var lineStart = pending.startIndex
        while let newline = pending.indexOfLineFeed(from: lineStart) {
            let line = pending[lineStart..<newline]
            if !droppingOversizedLine, line.count <= Self.maximumLineBytes,
               let record = autoreleasepool(invoking: { parser.consume(line: Data(line)) }) {
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
        let bytes = try handle.readDraining(upToCount: Int(min(UInt64(maxBytes), currentSize - offset)))
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
        guard consumeHeader(line) else {
            // Fail closed when provenance cannot be read. The archive lane can still parse normally.
            tailStartup = .unavailable
            isCaughtUp = true
            return
        }
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

    /// Reads the first line of a file resumed from a checkpoint, which the earlier run already read, so
    /// the parser knows the session the appended records belong to. The cursor stays where the
    /// checkpoint put it. Returns the bytes read.
    private mutating func restoreHeader(currentSize: UInt64) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = min(offset, UInt64(Self.maximumLineBytes) + 1)
        var header = Data()
        while UInt64(header.count) < limit {
            let chunk = try handle.readDraining(upToCount: Int(min(UInt64(Self.defaultBatchBytes), limit - UInt64(header.count))))
            if chunk.isEmpty { break }
            header.append(chunk)
            if chunk.contains(0x0A) { break }
        }
        guard let newline = header.firstIndex(of: 0x0A), consumeHeader(Data(header[..<newline])) else {
            tailStartup = .unavailable
            isCaughtUp = true
            return header.count
        }
        tailStartup = nil
        if parser.isSkippedSession {
            offset = currentSize
            isCaughtUp = true
        }
        return header.count
    }

    /// Feeds the session metadata line to the parser; false when the first line is not one.
    private mutating func consumeHeader(_ line: Data) -> Bool {
        guard line.count <= Self.maximumLineBytes,
              autoreleasepool(invoking: { (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["type"] as? String }) == "session_meta"
        else { return false }
        _ = parser.consume(line: line)
        return true
    }

    /// The file identity and offset a later run can resume from, once this reader has read the file to
    /// its end on a line boundary; nil while anything is unread or the first line could not be used.
    var checkpointPosition: (fileNumber: UInt64, offset: UInt64)? {
        guard isCaughtUp, offset > 0, pending.isEmpty, !droppingOversizedLine,
              tailStartup == nil || tailStartup == .context, let fileNumber else { return nil }
        return (fileNumber, offset)
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

extension Error {
    /// The file a reader was reading is gone (rotated away or deleted).
    var isMissingFile: Bool {
        guard let error = self as? CocoaError else { return false }
        return error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    }
}

extension FileHandle {
    /// `read(upToCount:)` returns an autoreleased buffer that a thread without a draining run loop
    /// (a command-line replay, a pool-less executor thread) keeps until it exits, so a large file held
    /// every batch read at once. The pool bounds that to one batch.
    func readDraining(upToCount count: Int) throws -> Data {
        try autoreleasepool { try read(upToCount: count) } ?? Data()
    }
}

extension Data {
    /// The index of the first line feed at or after `start`. `memchr` instead of
    /// `self[start...].firstIndex(of:)`, which walks a replay's multi-megabyte batches one `Data`
    /// subscript at a time and was half of the reader's time.
    func indexOfLineFeed(from start: Index) -> Index? {
        let firstOffset = start - startIndex
        let foundOffset: Int? = withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress, firstOffset < buffer.count,
                  let found = memchr(base + firstOffset, 0x0A, buffer.count - firstOffset)
            else { return nil }
            return base.distance(to: UnsafeRawPointer(found))
        }
        return foundOffset.map { startIndex + $0 }
    }
}
