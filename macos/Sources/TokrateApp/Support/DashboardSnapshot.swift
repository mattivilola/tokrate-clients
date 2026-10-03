import Foundation
import TokrateCore

enum DashboardRange: String, CaseIterable, Identifiable {
    case today, week
    var id: String { rawValue }
    var title: String { self == .today ? "Today" : "7 days" }
}

/// Pure presentation data: safe to construct for previews without any store, monitor, or network.
struct DashboardSnapshot {
    struct Bucket: Identifiable {
        var id: Date { date }
        let date: Date
        let median: Double
        let turns: Int
    }
    let range: DashboardRange
    let latest: TurnMetric?
    let points: [Bucket]
    let turnCount: Int
    let medianRate: Double?
    let medianTTFT: Double?
    let dates: ClosedRange<Date>

    init(records: [TurnMetric], range: DashboardRange, now: Date = .now, calendar: Calendar = .current) {
        self.range = range
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        let valid = records.filter {
            $0.completedAt >= cutoff && $0.completedAt <= now && $0.turnThroughputTPS.isFinite && $0.turnThroughputTPS >= 0
        }
        latest = valid.max { $0.completedAt < $1.completedAt }
        let start = range == .today ? calendar.startOfDay(for: now) : cutoff
        dates = start...max(now, start.addingTimeInterval(1))
        let selected = valid.filter { $0.completedAt >= start }
        turnCount = selected.count
        medianRate = Self.median(selected.map(\.turnThroughputTPS))
        medianTTFT = Self.median(selected.compactMap(\.codexTTFTSeconds).filter { $0.isFinite && $0 >= 0 })
        let maximumBuckets = range == .today ? 48 : 56
        let bucketWidth = max(1, dates.upperBound.timeIntervalSince(start) / Double(maximumBuckets))
        var buckets: [Int: [Double]] = [:]
        for record in selected {
            let index = min(maximumBuckets - 1, max(0, Int(record.completedAt.timeIntervalSince(start) / bucketWidth)))
            buckets[index, default: []].append(record.turnThroughputTPS)
        }
        points = buckets.keys.sorted().map { index in
            let values = buckets[index]!
            return Bucket(date: min(now, start.addingTimeInterval((Double(index) + 0.5) * bucketWidth)), median: Self.median(values)!, turns: values.count)
        }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? sorted[middle - 1] / 2 + sorted[middle] / 2 : sorted[middle]
    }

    static func rate(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
}
