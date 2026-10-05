import Foundation

/// In-memory, deduplicated seven-day history used by both clients.
public struct MetricHistory: Sendable {
    public static let maximumRecords = 50_000
    public static let retention: TimeInterval = 7 * 24 * 60 * 60
    public private(set) var records: [TurnMetric]

    public init(records: [TurnMetric] = [], now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        var unique: [String: TurnMetric] = [:]
        for record in records where record.completedAt >= cutoff && record.completedAt <= now {
            // Earlier builds saved measurement errors (see `ResponseSpeed`): a turn faster than any model
            // is dropped, response timing that does not add up is cleared. The cleaned state is saved next.
            guard record.hasPlausibleTurnThroughput else { continue }
            let hasResponse = record.responseOutputTokens != nil || record.responseDurationSeconds != nil || record.responseCount != nil
            unique[record.id] = hasResponse && !record.hasPlausibleResponseTiming ? record.withoutResponseTiming() : record
        }
        self.records = Array(unique.values.sorted { $0.completedAt > $1.completedAt }.prefix(Self.maximumRecords))
    }

    public mutating func upsert(_ record: TurnMetric, now: Date = .now) {
        prune(now: now)
        guard record.completedAt >= now.addingTimeInterval(-Self.retention), record.completedAt <= now else { return }
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            // A replay re-emits a turn before its delegated work is attributed again; the settled
            // total is never replaced by a pending one.
            let known = records[index].delegatedOutputTokens
            records[index] = record.delegatedOutputTokens == nil && known != nil
                ? record.withDelegatedOutputTokens(known) : record
        } else {
            records.append(record)
        }
        records.sort { $0.completedAt > $1.completedAt }
        if records.count > Self.maximumRecords { records = Array(records.prefix(Self.maximumRecords)) }
    }

    public mutating func prune(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        records.removeAll { $0.completedAt < cutoff || $0.completedAt > now }
    }

    public mutating func reset() {
        records.removeAll(keepingCapacity: false)
    }
}
