import CryptoKit
import Foundation

/// A session file that was read to its end, so the next launch can skip re-reading it: every record in
/// it is already in the saved history, and nothing but an append can add one.
///
/// The checkpoint describes the file exactly as the reader left it. At the next launch it applies only
/// to a file that is still that file (same identity, size and modification time), was read by the
/// same parser and metric versions and has been quiet for `minimumQuietSeconds`; any other file is read
/// in full as before. A digest of the path, a size and times only: no path (the contract keeps source
/// paths off disk), nothing from the file's content and no session identifier.
public struct SourceFileCheckpoint: Codable, Equatable, Sendable {
    /// The most checkpoints kept per source, matching the files a monitor watches at once.
    public static let maximumPerSource = 2_000
    /// A file modified more recently than this at launch is read in full: a turn that was still running
    /// when the app quit must not be resumed mid-turn and lost.
    public static let minimumQuietSeconds: TimeInterval = 600
    /// File times are compared within this: the two ways of reading one stat can round differently.
    private static let timeTolerance: TimeInterval = 0.001

    /// SHA-256 of the standardized file path, the key monitors watch it by (see `digest(ofPath:)`).
    public let pathDigest: String
    /// The inode, which changes when a file is replaced (the readers' replacement check).
    public let fileNumber: UInt64
    /// The bytes read, which is the whole file.
    public let size: UInt64
    /// Seconds since 1970. A plain number: the history file's ISO 8601 dates round to whole seconds.
    public let modificationTime: TimeInterval
    /// The parser and metric versions that read it; a change of either invalidates the checkpoint.
    public let versionKey: String

    public init(pathDigest: String, fileNumber: UInt64, size: UInt64, modifiedAt: Date, versionKey: String) {
        self.pathDigest = pathDigest
        self.fileNumber = fileNumber
        self.size = size
        modificationTime = modifiedAt.timeIntervalSince1970
        self.versionKey = versionKey
    }

    var modifiedAt: Date { Date(timeIntervalSince1970: modificationTime) }

    /// The digest a checkpoint stores for a standardized file path.
    public static func digest(ofPath path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The version key of records read by `parserVersion` and `metricVersion`.
    static func versionKey(parser: String, metric: String) -> String { "\(parser)|\(metric)" }

    /// The offset a reader can resume from when `url` is still the file this checkpoint describes and
    /// has been quiet for long enough at `now`.
    func resumeOffset(url: URL, size currentSize: Int, modifiedAt currentModification: Date, versionKey currentVersion: String, now: Date) -> UInt64? {
        guard versionKey == currentVersion, UInt64(clamping: currentSize) == size,
              abs(currentModification.timeIntervalSince1970 - modificationTime) < Self.timeTolerance,
              now.timeIntervalSince(currentModification) >= Self.minimumQuietSeconds,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == fileNumber else { return nil }
        return size
    }
}

/// The checkpoints saved with the history, by source. A source whose entry is empty has none.
public struct SourceCheckpoints: Codable, Equatable, Sendable {
    public var codex: [SourceFileCheckpoint] = []
    public var claudePrimary: [SourceFileCheckpoint] = []
    public var claudeSubagents: [SourceFileCheckpoint] = []

    public init() {}

    /// The files described, whichever source they belong to.
    public var pathDigests: Set<String> {
        Set((codex + claudePrimary + claudeSubagents).map(\.pathDigest))
    }

    /// Without what the history no longer holds records for (older than the retention) and within the
    /// per-source bound, newest files first.
    public func retained(now: Date = .now) -> SourceCheckpoints {
        let cutoff = now.addingTimeInterval(-MetricHistory.retention)
        func keep(_ checkpoints: [SourceFileCheckpoint]) -> [SourceFileCheckpoint] {
            Array(checkpoints.filter { $0.modifiedAt >= cutoff }
                .sorted { $0.modificationTime > $1.modificationTime }
                .prefix(SourceFileCheckpoint.maximumPerSource))
        }
        var result = SourceCheckpoints()
        result.codex = keep(codex)
        result.claudePrimary = keep(claudePrimary)
        result.claudeSubagents = keep(claudeSubagents)
        return result
    }
}
