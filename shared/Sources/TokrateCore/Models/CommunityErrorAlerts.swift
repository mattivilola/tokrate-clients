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

    /// The line for `alerts` at `now`, nil when nothing concerns the user and nothing recently cleared.
    ///
    /// - Parameters:
    ///   - alerts: the board's error alerts, in the server's order.
    ///   - usedModels: model ids with a turn in the user's local history in the last 7 days.
    ///   - localGroups: the user's own provider failures (`LocalProviderErrors.groups`).
    ///   - isSharing: whether sharing is on, so the user's own failures may be among the contributors.
    ///   - relativeTime: formats a time the way the dashboard shows "2 min ago".
    public mutating func line(
        alerts: [GlobalBoard.ErrorAlert],
        usedModels: Set<String>,
        localGroups: [LocalProviderErrors.Group],
        isSharing: Bool,
        now: Date,
        relativeTime: (Date) -> String
    ) -> Line? {
        trackRecovery(alerts: alerts, now: now)

        let dayCutoff = now.addingTimeInterval(-LocalProviderErrors.window)
        let hourCutoff = now.addingTimeInterval(-Self.recentFailureWindow)
        let failedLastDay = Set(localGroups.lazy.filter { $0.latest > dayCutoff }.map(\.model))
        let failedLastHour = Set(localGroups.lazy.filter { $0.latest > hourCutoff }.map(\.model))

        // One entry per model: the first alert in the server's order (a model can be alerted for more
        // than one provider). An alert without a counted error or contributor says nothing, and a
        // model the user just failed on whose only contributor is the user (others < 1) is the user's
        // own report: skipped, so the next relevant alert is used.
        var seen = Set<String>()
        let relevant = alerts.filter { alert in
            alert.overloaded + alert.serverError > 0
                && alert.failingContributors >= 1
                && (usedModels.contains(alert.model) || failedLastDay.contains(alert.model))
                && !(failedLastHour.contains(alert.model) && Self.otherContributors(of: alert, isSharing: isSharing) < 1)
                && seen.insert(alert.model).inserted
        }
        // A stable partition: models the user just failed on first, then the server's order.
        let ordered = relevant.filter { failedLastHour.contains($0.model) }
            + relevant.filter { !failedLastHour.contains($0.model) }

        if let main = ordered.first {
            shown.formUnion(ordered.prefix(1 + Self.maximumAlsoModels).map(\.model))
            var text = Self.sentence(for: main, ownFailure: failedLastHour.contains(main.model), isSharing: isSharing, relativeTime: relativeTime)
            let also = ordered.dropFirst().prefix(Self.maximumAlsoModels).map(\.model)
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

    /// The contributors besides the user: the user's own counts may be among the board's when sharing is on.
    private static func otherContributors(of alert: GlobalBoard.ErrorAlert, isSharing: Bool) -> Int {
        isSharing ? alert.failingContributors - 1 : alert.failingContributors
    }

    private static func sentence(
        for alert: GlobalBoard.ErrorAlert, ownFailure: Bool, isSharing: Bool, relativeTime: (Date) -> String
    ) -> String {
        if ownFailure {
            let others = otherContributors(of: alert, isSharing: isSharing)
            let noun = others == 1 ? "contributor" : "contributors"
            return "It’s not just you: \(others) other \(noun) hit provider errors on \(alert.model) in the last hour."
        }
        var counts: [String] = []
        if alert.overloaded > 0 { counts.append("\(alert.overloaded) overloaded / at capacity") }
        if alert.serverError > 0 { counts.append("\(alert.serverError) \(alert.serverError == 1 ? "server error" : "server errors")") }
        let contributors = alert.failingContributors == 1 ? "contributor" : "contributors"
        return "Tokrate contributors are reporting provider errors on \(alert.model): \(counts.joined(separator: " and ")) from \(alert.failingContributors) \(contributors) in the last hour, latest \(relativeTime(alert.lastFailureAt))."
    }
}
