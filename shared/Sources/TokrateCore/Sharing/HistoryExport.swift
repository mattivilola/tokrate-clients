import Foundation

/// Turns replayed turns into the upload samples of the one-off history export. It applies the live
/// sharing eligibility (`SharedSample.rejection(of:)`) and the live mapping (`SharedSample.init`) to
/// every turn; the only rule of its own is the completion-time window that replaces the live
/// "completed after consent" rule, which is a consent rule rather than a parsing rule.
public enum HistoryExport {
    public enum Skip: Hashable, Sendable {
        case outsideWindow
        case rejected(SharedSample.Rejection)

        public var label: String {
            switch self {
            case .outsideWindow: "outside the date range"
            case .rejected(let reason): reason.rawValue
            }
        }
    }

    public struct Result: Sendable {
        /// Sorted by `observedAt`, then by completion time.
        public let samples: [SharedSample]
        public let skipped: [Skip: Int]
        /// The same skips by the turn's `client`.
        public let skippedByClient: [String: [Skip: Int]]
    }

    /// Keeps turns whose completion time is in `window` (inclusive start, exclusive end). Each turn id
    /// counts once, so a turn re-emitted with its settled delegated total is one sample.
    public static func samples(
        from metrics: [TurnMetric], window: Range<Date>, makeSampleID: () -> UUID = UUID.init
    ) -> Result {
        var skipped: [Skip: Int] = [:]
        var skippedByClient: [String: [Skip: Int]] = [:]
        func skip(_ reason: Skip, _ metric: TurnMetric) {
            skipped[reason, default: 0] += 1
            skippedByClient[metric.client, default: [:]][reason, default: 0] += 1
        }
        var mapped: [(sample: SharedSample, completedAt: Date)] = []
        for metric in metrics.sorted(by: { $0.completedAt < $1.completedAt }) {
            guard window.contains(metric.completedAt) else { skip(.outsideWindow, metric); continue }
            guard let sample = SharedSample(metric, sampleId: makeSampleID()) else {
                skip(.rejected(SharedSample.rejection(of: metric) ?? .unsupportedSourceTuple), metric)
                continue
            }
            mapped.append((sample, metric.completedAt))
        }
        mapped.sort { ($0.sample.observedAt, $0.completedAt) < ($1.sample.observedAt, $1.completedAt) }
        return Result(samples: mapped.map(\.sample), skipped: skipped, skippedByClient: skippedByClient)
    }

    /// One replayed turn per id: a turn first emitted without its delegated total is replaced by the
    /// emission that carries it, and the first final emission is kept, as the app shares a record once,
    /// when it is both new and final.
    public static func deduplicated(_ metrics: [TurnMetric]) -> [TurnMetric] {
        var byID: [String: TurnMetric] = [:]
        for metric in metrics {
            if byID[metric.id]?.isDelegationFinal == true { continue }
            byID[metric.id] = metric
        }
        return Array(byID.values)
    }
}
