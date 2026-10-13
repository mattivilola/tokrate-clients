import Foundation

/// The community provider-error line (contract "Community error alerts (0.1.23)"): which of the
/// board's error alerts concern the user, the one passive sentence about them, and the short
/// "contributors no longer report provider errors" note once an alert that was shown has cleared.
///
/// Pure apart from the recovery memory, which lives in this value (in memory only, never persisted):
/// the caller feeds it the current alerts every time the board or the clock moves.
public struct CommunityErrorAlerts: Sendable {
    /// What the line is, which decides how a dashboard styles it.
    public enum Kind: Sendable, Equatable {
        /// Contributors are reporting provider errors on a model the user uses.
        case alert
        /// An alert that was shown has cleared.
        case recovery
        /// Sharing is off, so the community cannot say whether others hit the same errors.
        case sharingHint
    }

    public struct Line: Sendable, Equatable {
        public let kind: Kind
        public let text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// One alert that concerns the user, as the line and the notifications both read it.
    public struct RelevantAlert: Sendable, Equatable {
        public let alert: GlobalBoard.ErrorAlert
        /// The user had a provider failure on this model in the last hour.
        public let ownFailure: Bool
        /// The contributors besides the user: the user's own counts may be among the board's when
        /// sharing is on.
        public let otherContributors: Int

        public var model: String { alert.model }

        public init(alert: GlobalBoard.ErrorAlert, ownFailure: Bool, otherContributors: Int) {
            self.alert = alert
            self.ownFailure = ownFailure
            self.otherContributors = otherContributors
        }
    }

    /// Models the user ran a turn of within this window concern them.
    public static let usedModelWindow: TimeInterval = 7 * 24 * 3_600
    /// A local failure within this window makes the line say "It’s not just you" and ranks it first.
    public static let recentFailureWindow: TimeInterval = 3_600
    /// How long the recovery note replaces the missing alert line.
    public static let recoveryWindow: TimeInterval = 30 * 60
    /// At most this many other models follow the main one.
    static let maximumAlsoModels = 2
    /// Shown under the local provider-error line while sharing is off.
    public static let sharingHint = "Turn on sharing to see whether other contributors hit the same errors."

    /// Models whose alert has been shown in this run and is still on the board.
    private var shown: Set<String> = []
    /// When each such model's alert left the board; forgotten after the recovery window.
    private var cleared: [String: Date] = [:]

    public init() {}

    /// Forgets everything shown, for example when sharing is switched off: with no board there is
    /// nothing to have cleared.
    public mutating func reset() {
        shown.removeAll()
        cleared.removeAll()
    }

    /// The alerts that concern the user, in display order: the one place that decides relevance, so
    /// the line and the notifications can never disagree.
    ///
    /// One entry per model (the first alert in the server's order; a model can be alerted for more than
    /// one provider). An alert without a counted error or contributor says nothing, and a model the user
    /// just failed on whose only contributor is the user (others < 1) is the user's own report: skipped,
    /// so the next relevant alert is used. Models the user just failed on come first, then the server's
    /// order (a stable partition).
    ///
    /// - Parameters:
    ///   - alerts: the board's error alerts, in the server's order.
    ///   - usedModels: model ids with a turn in the user's local history in the last 7 days.
    ///   - localGroups: the user's own provider failures (`LocalProviderErrors.groups`).
    ///   - isSharing: whether sharing is on, so the user's own failures may be among the contributors.
    public static func relevantAlerts(
        _ alerts: [GlobalBoard.ErrorAlert],
        usedModels: Set<String>,
        localGroups: [LocalProviderErrors.Group],
        isSharing: Bool,
        now: Date
    ) -> [RelevantAlert] {
        let dayCutoff = now.addingTimeInterval(-LocalProviderErrors.window)
        let hourCutoff = now.addingTimeInterval(-recentFailureWindow)
        let failedLastDay = Set(localGroups.lazy.filter { $0.latest > dayCutoff }.map(\.model))
        let failedLastHour = Set(localGroups.lazy.filter { $0.latest > hourCutoff }.map(\.model))

        var seen = Set<String>()
        let relevant = alerts.compactMap { alert -> RelevantAlert? in
            let others = isSharing ? alert.failingContributors - 1 : alert.failingContributors
            let ownFailure = failedLastHour.contains(alert.model)
            guard alert.overloaded + alert.serverError > 0,
                  alert.failingContributors >= 1,
                  usedModels.contains(alert.model) || failedLastDay.contains(alert.model),
                  !(ownFailure && others < 1),
                  seen.insert(alert.model).inserted
            else { return nil }
            return RelevantAlert(alert: alert, ownFailure: ownFailure, otherContributors: others)
        }
        return relevant.filter(\.ownFailure) + relevant.filter { !$0.ownFailure }
    }

    /// The line for `alerts` at `now`, nil when nothing concerns the user and nothing recently cleared.
    ///
    /// - Parameters:
    ///   - alerts: the board's error alerts, which decide when a shown alert has cleared.
    ///   - relevant: `relevantAlerts` of the same alerts.
    ///   - relativeTime: formats a time the way the dashboard shows "2 min ago".
    public mutating func line(
        alerts: [GlobalBoard.ErrorAlert],
        relevant: [RelevantAlert],
        now: Date,
        relativeTime: (Date) -> String
    ) -> Line? {
        trackRecovery(alerts: alerts, now: now)

        if let main = relevant.first {
            shown.formUnion(relevant.prefix(1 + Self.maximumAlsoModels).map(\.model))
            var text = Self.sentence(for: main, relativeTime: relativeTime)
            let also = relevant.dropFirst().prefix(Self.maximumAlsoModels).map(\.model)
            if !also.isEmpty { text += " Also: " + also.joined(separator: ", ") }
            return Line(kind: .alert, text: text)
        }

        if let recovered = cleared.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) {
            return Line(
                kind: .recovery,
                text: "\(recovered.key): contributors no longer report provider errors (cleared \(relativeTime(recovered.value)))."
            )
        }
        return nil
    }

    /// Moves models whose alert left the board into `cleared`, and drops the ones whose time is up
    /// or that are alerted again.
    private mutating func trackRecovery(alerts: [GlobalBoard.ErrorAlert], now: Date) {
        let current = Set(alerts.map(\.model))
        for model in shown where !current.contains(model) {
            shown.remove(model)
            cleared[model] = now
        }
        let cutoff = now.addingTimeInterval(-Self.recoveryWindow)
        cleared = cleared.filter { !current.contains($0.key) && $0.value > cutoff }
    }

    private static func sentence(for relevant: RelevantAlert, relativeTime: (Date) -> String) -> String {
        let alert = relevant.alert
        if relevant.ownFailure {
            return "It’s not just you: \(contributorCount(relevant.otherContributors, adjective: "other")) hit provider errors on \(alert.model) in the last hour."
        }
        return "Tokrate contributors are reporting provider errors on \(alert.model): \(counts(of: alert)) from \(contributorCount(alert.failingContributors)) in the last hour, latest \(relativeTime(alert.lastFailureAt))."
    }

    /// "3 contributors", "1 other contributor".
    static func contributorCount(_ count: Int, adjective: String? = nil) -> String {
        let noun = count == 1 ? "contributor" : "contributors"
        return ([String(count)] + (adjective.map { [$0] } ?? []) + [noun]).joined(separator: " ")
    }

    /// "{n} overloaded / at capacity", "{m} server error(s)" or both joined with " and ".
    static func counts(of alert: GlobalBoard.ErrorAlert) -> String {
        var counts: [String] = []
        if alert.overloaded > 0 { counts.append("\(alert.overloaded) overloaded / at capacity") }
        if alert.serverError > 0 { counts.append("\(alert.serverError) \(alert.serverError == 1 ? "server error" : "server errors")") }
        return counts.joined(separator: " and ")
    }
}
