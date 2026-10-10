import Foundation

/// Sums request outcomes per five-minute bucket and identity until each bucket's totals may be queued
/// (contract "Request outcomes (0.1.22)", "Collection"). Memory only: nothing here is persisted, and
/// `removeAll` forgets every pending count.
///
/// - An outcome is eligible only when it is at or after the start of the current sharing consent and
///   not in the future, and a dedupe key already seen is ignored, so re-reading a file never counts
///   twice. The key set is bounded.
/// - Totals are summed per (bucket of the outcome's own timestamp, client, client version, parser
///   version, model, provider). A bucket's totals are due one full period after the bucket closes
///   (bucket start + 600 s), the moment its samples become uploadable. An outcome for a bucket that is
///   already due starts a new group, due at the next period boundary.
struct RequestOutcomeAggregator {
    static let bucketSeconds: TimeInterval = 300
    /// Dedupe keys remembered; the oldest are forgotten first.
    static let maximumRememberedKeys = 50_000
    /// An outcome older than this when it is due is dropped, like a sample.
    static let maximumAge: TimeInterval = 86_400

    struct Identity: Hashable {
        let client: String
        let clientVersion: String
        let parserVersion: String
        let model: String
        let provider: String
    }

    struct Bucket: Hashable {
        /// Start of the five-minute UTC bucket, in epoch seconds.
        let start: TimeInterval
        let identity: Identity
    }

    /// The totals of one bucket and identity, waiting for `dueAt`.
    struct Group {
        let bucket: Bucket
        let dueAt: Date
        var succeeded = 0
        var overloaded = 0
        var serverError = 0

        var observedAt: Date { Date(timeIntervalSince1970: bucket.start) }
    }

    private var seen = BoundedSet<String>(limit: RequestOutcomeAggregator.maximumRememberedKeys)
    private var groups: [Bucket: Group] = [:]

    var isEmpty: Bool { groups.isEmpty }

    /// When the earliest pending group is due.
    var earliestDueAt: Date? { groups.values.map(\.dueAt).min() }

    /// Counts the eligible outcomes. A dedupe key is remembered only once its outcome is counted, so an
    /// outcome that is not eligible yet (dated in the future) can still count later.
    mutating func add(_ outcomes: [RequestOutcome], consentStartedAt: Date, now: Date) {
        for outcome in outcomes where outcome.occurredAt >= consentStartedAt && outcome.occurredAt <= now {
            guard seen.insert(outcome.dedupeKey) else { continue }
            let start = floor(outcome.occurredAt.timeIntervalSince1970 / Self.bucketSeconds) * Self.bucketSeconds
            let bucket = Bucket(start: start, identity: Identity(
                client: outcome.client, clientVersion: outcome.clientVersion, parserVersion: outcome.parserVersion,
                model: outcome.model, provider: outcome.provider
            ))
            var group = groups[bucket] ?? Group(bucket: bucket, dueAt: Self.dueDate(bucketStart: start, firstSeenAt: now))
            switch outcome.kind {
            case .succeeded: group.succeeded += 1
            case .overloaded: group.overloaded += 1
            case .serverError: group.serverError += 1
            }
            groups[bucket] = group
        }
    }

    /// Removes and returns the groups that are due at `now`, oldest bucket first. Groups whose bucket is
    /// more than 24 hours old are dropped instead.
    mutating func takeDue(now: Date) -> [Group] {
        let due = groups.values.filter { $0.dueAt <= now }
        for group in due { groups.removeValue(forKey: group.bucket) }
        return due
            .filter { now.timeIntervalSince($0.observedAt) <= Self.maximumAge }
            .sorted { ($0.bucket.start, $0.dueAt) < ($1.bucket.start, $1.dueAt) }
    }

    mutating func removeAll() {
        seen = BoundedSet(limit: Self.maximumRememberedKeys)
        groups.removeAll()
    }

    /// Bucket start + 600 s, or the next period boundary when that has passed already.
    private static func dueDate(bucketStart: TimeInterval, firstSeenAt now: Date) -> Date {
        let onTime = bucketStart + 2 * bucketSeconds
        guard now.timeIntervalSince1970 >= onTime else { return Date(timeIntervalSince1970: onTime) }
        return Date(timeIntervalSince1970: (now.timeIntervalSince1970 / bucketSeconds).rounded(.up) * bucketSeconds)
    }
}
