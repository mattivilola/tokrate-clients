import Foundation

/// In-memory, deduplicated seven-day history used by both clients.
public struct MetricHistory: Sendable {
    public static let maximumRecords = 50_000
    public static let retention: TimeInterval = 7 * 24 * 60 * 60
    public private(set) var records: [TurnMetric]

    public init(records: [TurnMetric] = [], now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        var unique: [String: TurnMetric] = [:]
        for record in records where record.completedAt >= cutoff && record.completedAt <= now { unique[record.id] = record }
        self.records = Array(unique.values.sorted { $0.completedAt > $1.completedAt }.prefix(Self.maximumRecords))
    }

    public mutating func upsert(_ record: TurnMetric, now: Date = .now) {
        prune(now: now)
        guard record.completedAt >= now.addingTimeInterval(-Self.retention), record.completedAt <= now else { return }
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
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
