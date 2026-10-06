import Foundation

/// How much of a source the monitors read: the live app's bounded window, or the full replay of a
/// longer window that the one-off history export uses. The monitors share every parsing, pairing and
/// attribution rule between the two; only these bounds differ.
public struct MonitorScope: Sendable, Equatable {
    /// Files, databases and messages older than this are not read.
    public let retention: TimeInterval
    /// Multiplies every per-source capacity bound (files, tracked work items, pending turns, indexed
    /// messages), so a longer window does not silently drop its oldest items, and the bytes read per
    /// poll, so a replay is not a few thousand polls of the live monitor's budget.
    public let capacityScale: Int
    /// Read each file from its first byte with a single reader instead of a recent-tail reader plus an
    /// archive reader. The result is the same records; there is no live tail to prioritize.
    public let replaysFromStart: Bool

    public static let live = MonitorScope(retention: MetricHistory.retention, capacityScale: 1, replaysFromStart: false)

    /// A complete replay of `retention` seconds of history.
    public static func replay(retention: TimeInterval) -> MonitorScope {
        MonitorScope(retention: retention, capacityScale: 50, replaysFromStart: true)
    }

    var maximumFiles: Int { SourceFileCheckpoint.maximumPerSource * capacityScale }
    var maximumWorkItems: Int { DelegationAttributor.maximumWorkItems * capacityScale }
    var maximumPendingTurns: Int { DelegationAttributor.maximumPendingTurns * capacityScale }
    var maximumPollBytes: Int { 1_048_576 * capacityScale }
    var readerBatchBytes: Int { 65_536 * capacityScale }
    var maximumIndexedMessages: Int { OpenCodeMonitor.maximumIndexedMessages * capacityScale }
}
