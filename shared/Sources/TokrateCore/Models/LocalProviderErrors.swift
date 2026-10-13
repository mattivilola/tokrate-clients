import Foundation

/// The user's own provider-side failures of the last 24 hours (contract "Local provider errors (0.1.23)").
///
/// It ingests the request outcomes the monitors produce, whether or not sharing is on, and keeps only
/// the failures (`overloaded`, `serverError`) per (client, model, kind), so a "model at capacity" error
/// can be recognised as the provider's and not the user's connection. Memory only: nothing here is
/// persisted, exported or uploaded, and no error text exists to keep.
public struct LocalProviderErrors {
    /// How long a failure stays on the line.
    public static let window: TimeInterval = 24 * 3_600
    /// At most this many groups are kept; the group with the oldest latest failure is dropped first.
    public static let maximumGroups = 200
    /// At most this many failure times are kept per group (oldest dropped first), so one runaway
    /// outage cannot grow the summary without bound.
    static let maximumFailuresPerGroup = 1_000
    /// At most this many dedupe keys are remembered, like the sharing counts.
    static let maximumRememberedKeys = 50_000
    /// At most this many other groups follow the main one.
    static let maximumAlsoGroups = 2

    /// The failures of one (client, model, kind) in the window.
    public struct Group: Equatable, Sendable {
        public let client: String
        public let model: String
        public let kind: RequestOutcome.Kind
        /// Failure times, oldest first; never empty.
        fileprivate(set) var failures: [Date]

        public var count: Int { failures.count }
        public var latest: Date { failures[failures.count - 1] }
    }

    private struct Key: Hashable, Sendable {
        let client: String
        let model: String
        let kind: RequestOutcome.Kind
    }

    private var groups: [Key: Group] = [:]
    private var seen = BoundedSet<String>(limit: LocalProviderErrors.maximumRememberedKeys)

    public init() {}

    /// Counts the failures among `outcomes`. Successes, outcomes older than the window and outcomes
    /// whose dedupe key was already seen are ignored; a time in the future counts as now.
    public mutating func add(_ outcomes: [RequestOutcome], now: Date = .now) {
        prune(now: now)
        for outcome in outcomes where outcome.kind != .succeeded {
            guard outcome.occurredAt > now.addingTimeInterval(-Self.window),
                  seen.insert(outcome.dedupeKey)
            else { continue }
            let key = Key(client: outcome.client, model: outcome.model, kind: outcome.kind)
            var group = groups[key] ?? Group(client: key.client, model: key.model, kind: key.kind, failures: [])
            let time = min(outcome.occurredAt, now)
            // Outcomes arrive nearly in order: insert after the last time that is not later.
            let index = group.failures.lastIndex { $0 <= time }.map { $0 + 1 } ?? 0
            group.failures.insert(time, at: index)
            if group.failures.count > Self.maximumFailuresPerGroup { group.failures.removeFirst() }
            groups[key] = group
        }
        while groups.count > Self.maximumGroups, let oldest = groups.values.min(by: Self.isOlder) {
            groups[Key(client: oldest.client, model: oldest.model, kind: oldest.kind)] = nil
        }
    }

    /// Forgets the failures older than the window.
    public mutating func prune(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Self.window)
        for (key, var group) in groups {
            group.failures.removeAll { $0 <= cutoff }
            groups[key] = group.failures.isEmpty ? nil : group
        }
    }

    /// The groups with a failure in the window, the most recent failure first.
    public func groups(now: Date = .now) -> [Group] {
        let cutoff = now.addingTimeInterval(-Self.window)
        return groups.values.compactMap { group -> Group? in
            var group = group
            group.failures.removeAll { $0 <= cutoff }
            return group.failures.isEmpty ? nil : group
        }
        .sorted(by: Self.isMoreRecent)
    }

    /// The one passive dashboard line, nil when nothing failed in the last 24 hours. `relativeTime`
    /// formats the time of a group's latest failure the way the dashboard shows "2 min ago".
    public func line(now: Date = .now, relativeTime: (Date) -> String) -> String? {
        let current = groups(now: now)
        guard let main = current.first else { return nil }
        let times = main.count == 1 ? "time" : "times"
        let recently = relativeTime(main.latest)
        var line: String
        switch main.kind {
        case .overloaded:
            let label = main.client == "codex" ? "model at capacity" : "overloaded"
            line = "You hit “\(label)” \(main.count) \(times) on \(main.model) in the last 24 hours, most recently \(recently). That’s the provider at capacity, not your connection."
        case .serverError, .succeeded: // a group only ever holds failures
            let errors = main.count == 1 ? "server error" : "server errors"
            line = "\(main.model) returned \(main.count) \(errors) in the last 24 hours, most recently \(recently). That’s a failure at the provider, not your connection."
        }
        let others = current.dropFirst().prefix(Self.maximumAlsoGroups)
        if !others.isEmpty {
            line += " Also: " + others.map { "\($0.model) (\($0.count))" }.joined(separator: ", ")
        }
        return line
    }

    private static func isOlder(_ lhs: Group, _ rhs: Group) -> Bool { lhs.latest < rhs.latest }

    /// Most recent latest failure first; a fixed order by name when the times coincide.
    private static func isMoreRecent(_ lhs: Group, _ rhs: Group) -> Bool {
        if lhs.latest != rhs.latest { return lhs.latest > rhs.latest }
        return (lhs.client, lhs.model, lhs.kind.rawValue) < (rhs.client, rhs.model, rhs.kind.rawValue)
    }
}
