import Foundation
import TokrateCore

/// The efficiency indicator (efficiency-v1): how many output tokens a model spends to finish one
/// request compared with a typical request. Fewer tokens score higher; 100 is typical.
///
/// Pure and local: the reference spans the whole retained history (7 days), independent of the
/// chart range, so the value stays stable while the range toggle moves.
enum EfficiencyIndicator {
    /// Turns under this many total tokens are trivial or automated and never count.
    static let minimumTotalTokens = 200
    /// Eligible turns a group (and the reference) needs before an indicator is shown.
    static let minimumTurns = 20
    /// Eligible turns a chart bucket needs; fewer leave a gap.
    static let minimumBucketTurns = 3

    /// Model plus reasoning effort, combined across coding tools, providers and versions.
    struct Key: Hashable, Sendable {
        let model: String
        /// "unknown" when the turn reported no effort.
        let effort: String

        init(model: String, effort: String) {
            self.model = model
            self.effort = effort
        }

        init?(_ metric: TurnMetric) {
            guard let model = metric.model, !model.isEmpty else { return nil }
            self.init(model: model, effort: metric.reasoningEffort ?? "unknown")
        }

        init?(_ cohort: ModelCohort) {
            guard let model = cohort.model, !model.isEmpty else { return nil }
            self.init(model: model, effort: cohort.reasoningEffort ?? "unknown")
        }

        var id: String { "\(model)|\(effort)" }
    }

    /// R: the median total tokens over every eligible turn.
    struct Reference: Equatable, Sendable {
        let median: Double
        let turns: Int
    }

    /// One model and effort over the eligible turns of the window.
    struct Row: Identifiable, Equatable, Sendable {
        var id: String { group.id }
        let group: Key
        /// The provider when every turn of the group names the same one, else nil.
        let provider: String?
        /// Eligible turns.
        let turns: Int
        /// Nil below 20 eligible turns or without a reference.
        let indicator: Int?
        let medianTokens: Double
        let p25Tokens: Double
        let p75Tokens: Double
        /// Median of reasoning/output over turns that report reasoning tokens; nil without any.
        let reasoningShare: Double?
        /// Σ delegated / Σ total.
        let delegatedShare: Double
        let latestAt: Date

        var model: String { group.model }
        var effort: String { group.effort }
        var hasIndicator: Bool { indicator != nil }
    }

    // MARK: Eligibility

    /// Output plus delegated output tokens; nil while the delegated work is not final or not applicable.
    static func totalTokens(_ metric: TurnMetric) -> Int? {
        guard metric.outputTokens >= 0, let delegated = metric.delegatedOutputTokens, delegated >= 0 else { return nil }
        return metric.outputTokens + delegated
    }

    /// The turn's total tokens when it is eligible for the indicator, else nil.
    static func eligibleTotal(_ metric: TurnMetric) -> Int? {
        guard metric.sourceKind == "primary",
              Key(metric) != nil,
              metric.isSupportedSourceTuple,
              let total = totalTokens(metric), total >= minimumTotalTokens else { return nil }
        return total
    }

    // MARK: Statistics

    /// Linear-interpolation percentile of an ascending list (`fraction` 0.5 is the usual median).
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let position = Double(sorted.count - 1) * fraction
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    private static func medianOf(_ values: [Double]) -> Double? { percentile(values.sorted(), 0.5) }

    /// 100 = typical; 200 = half the tokens; 50 = twice the tokens.
    static func indicator(reference: Double, median: Double) -> Int { Int((100 * reference / median).rounded()) }

    /// R over every eligible turn; nil below the 20-turn floor.
    static func reference(in records: [TurnMetric]) -> Reference? {
        let totals = records.compactMap(eligibleTotal).map(Double.init)
        guard totals.count >= minimumTurns, let median = medianOf(totals), median > 0 else { return nil }
        return Reference(median: median, turns: totals.count)
    }

    /// One row per model and effort.
    static func rows(in records: [TurnMetric], reference: Reference?) -> [Row] {
        let eligible = records.filter { eligibleTotal($0) != nil }
        return Dictionary(grouping: eligible) { Key($0)! }.map { group, turns in
            let totals = turns.compactMap(eligibleTotal).map(Double.init).sorted()
            let groupMedian = percentile(totals, 0.5) ?? 0
            let shares = turns.compactMap { turn -> Double? in
                guard let reasoning = turn.reasoningOutputTokens, reasoning >= 0, turn.outputTokens > 0 else { return nil }
                return Double(reasoning) / Double(turn.outputTokens)
            }
            let sumTotal = totals.reduce(0, +)
            let sumDelegated = turns.reduce(0) { $0 + ($1.delegatedOutputTokens ?? 0) }
            let providers = Set(turns.map { $0.provider ?? "unknown" })
            return Row(
                group: group,
                provider: providers.count == 1 ? providers.first : nil,
                turns: turns.count,
                indicator: reference.flatMap { turns.count >= minimumTurns && groupMedian > 0 ? indicator(reference: $0.median, median: groupMedian) : nil },
                medianTokens: groupMedian,
                p25Tokens: percentile(totals, 0.25) ?? 0,
                p75Tokens: percentile(totals, 0.75) ?? 0,
                reasoningShare: medianOf(shares),
                delegatedShare: sumTotal > 0 ? Double(sumDelegated) / sumTotal : 0,
                latestAt: turns.map(\.completedAt).max() ?? .distantPast
            )
        }
    }

    /// Chart points over `bucketCount` equal buckets of `start ..< now`. With a group a bucket is
    /// the indicator against the shared reference (a gap without one); without a group it is the
    /// median total tokens per request. Either way a bucket needs 3 eligible turns.
    static func points(
        in records: [TurnMetric],
        group: Key?,
        reference: Reference?,
        start: Date,
        now: Date,
        duration: TimeInterval,
        bucketCount: Int
    ) -> [DashboardSnapshot.Bucket] {
        let width = max(1, duration / Double(bucketCount))
        var grouped: [Int: [Double]] = [:]
        for record in records where record.completedAt >= start && record.completedAt <= now {
            guard let total = eligibleTotal(record), group == nil || Key(record) == group else { continue }
            let index = min(bucketCount - 1, max(0, Int(record.completedAt.timeIntervalSince(start) / width)))
            grouped[index, default: []].append(Double(total))
        }
        return grouped.keys.sorted().compactMap { index in
            let totals = grouped[index]!
            guard totals.count >= minimumBucketTurns, let median = medianOf(totals) else { return nil }
            let value: Double
            if group == nil {
                value = median
            } else if let reference, median > 0 {
                value = Double(indicator(reference: reference.median, median: median))
            } else {
                return nil
            }
            return DashboardSnapshot.Bucket(
                date: min(now, start.addingTimeInterval((Double(index) + 0.5) * width)),
                median: value,
                turns: totals.count
            )
        }
    }

    // MARK: Ordering

    /// Highest indicator first; groups without one follow, the most evidenced first.
    static func ordered(_ rows: [Row], by sort: EfficiencyComparisonSort) -> [Row] {
        rows.sorted { left, right in
            switch sort {
            case .recent:
                return left.latestAt == right.latestAt ? left.id < right.id : left.latestAt > right.latestAt
            case .higher:
                if left.indicator != right.indicator { return (left.indicator ?? -1) > (right.indicator ?? -1) }
                if left.turns != right.turns { return left.turns > right.turns }
                return left.latestAt == right.latestAt ? left.id < right.id : left.latestAt > right.latestAt
            }
        }
    }

    /// Bar scale: the largest indicator, never below the 100 "typical" tick.
    static func scaleMaximum(_ rows: [Row]) -> Int { rows.reduce(100) { max($0, $1.indicator ?? 0) } }

    // MARK: Formatting

    /// Token counts compactly: 950, 4.9k, 12k, 1.2M.
    static func compactTokens(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let rounded = value.rounded()
        let magnitude = abs(rounded)
        guard magnitude >= 1_000 else { return String(Int(rounded)) }
        let (scaled, suffix) = magnitude < 999_500 ? (rounded / 1_000, "k") : (rounded / 1_000_000, "M")
        var text = abs(scaled) < 9.95 ? String(format: "%.1f", (scaled * 10).rounded() / 10) : String(Int(scaled.rounded()))
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text + suffix
    }

    /// "42%" from a 0...1 share; an em dash without a value.
    static func percentText(_ share: Double?) -> String {
        guard let share, share.isFinite else { return "—" }
        return "\(Int((share * 100).rounded()))%"
    }
}

/// Sorting for the efficiency list.
enum EfficiencyComparisonSort: String, CaseIterable, Identifiable {
    case recent, higher
    var id: String { rawValue }
    var title: String { self == .recent ? "Most recent" : "Higher efficiency" }
}
