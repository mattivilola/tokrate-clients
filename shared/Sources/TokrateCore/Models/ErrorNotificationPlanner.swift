import Foundation

/// One operating-system notification about a model's provider errors.
public struct ErrorNotification: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// Contributors started reporting provider errors on the model.
        case start
        /// The model's episode ended: contributors no longer report errors.
        case recovery
    }

    public let kind: Kind
    public let model: String
    public let title: String
    public let body: String

    public init(kind: Kind, model: String, title: String, body: String) {
        self.kind = kind
        self.model = model
        self.title = title
        self.body = body
    }

    /// Stable per model and kind, so a newer notification replaces an older one of the same kind.
    public var identifier: String { "provider-errors.\(kind.rawValue).\(model)" }
}

/// Decides which community error alerts become notifications (contract "Error notifications (0.1.23)").
///
/// Pure apart from its episode memory, which lives in this value (in memory only, never persisted): the
/// caller feeds it the relevant alerts every time the board or the clock moves and posts what it
/// returns. Per model an episode starts when the model's alert first appears and ends when it has been
/// absent for 30 minutes; the start is notified once, the end only if the start was.
public struct ErrorNotificationPlanner: Sendable {
    /// An episode that has been absent this long is over.
    public static let recoveryWindow: TimeInterval = CommunityErrorAlerts.recoveryWindow
    /// At most this many notifications are posted within `capWindow`.
    public static let maximumPerHour = 3
    public static let capWindow: TimeInterval = 3_600

    private struct Episode: Sendable {
        /// Whether the start was posted (or counted as already notified): only then is the end notified.
        var startNotified: Bool
        /// When the model left the alerts; nil while it is present.
        var absentSince: Date?
    }

    private var episodes: [String: Episode] = [:]
    /// Alerts present when the baseline is taken are marked notified without posting. Taken at the
    /// first board after the setting and sharing are both on, and lost again when either goes off.
    private var hasBaseline = false
    /// When a board was last planned from; a gap as long as the recovery window ends every episode.
    private var lastBoardAt: Date?
    private var postedAt: [Date] = []

    public init() {}

    /// The notifications to post for the alerts at `now`.
    ///
    /// - Parameters:
    ///   - relevant: `CommunityErrorAlerts.relevantAlerts` of the current board, nil while there is no
    ///     board (sharing just turned on, or the fetch failed): nothing happens then, and the baseline
    ///     waits for the first board.
    ///   - isSharing: whether sharing is on; alerts come from the community board.
    ///   - isEnabled: the user's notification setting.
    public mutating func plan(
        relevant: [CommunityErrorAlerts.RelevantAlert]?,
        isSharing: Bool,
        isEnabled: Bool,
        now: Date
    ) -> [ErrorNotification] {
        guard isSharing, isEnabled else {
            reset()
            return []
        }
        guard let relevant else { return [] }
        postedAt.removeAll { now.timeIntervalSince($0) >= Self.capWindow }

        guard hasBaseline else {
            hasBaseline = true
            lastBoardAt = now
            episodes = Dictionary(uniqueKeysWithValues: relevant.map { ($0.model, Episode(startNotified: true, absentSince: nil)) })
            return []
        }

        // Boards were missing for the whole recovery window (the Mac slept, the fetch kept failing): an
        // alert that is there again starts a new episode, and nothing is said about the end of the old
        // one.
        let boardsWereMissing = lastBoardAt.map { now.timeIntervalSince($0) >= Self.recoveryWindow } ?? false
        lastBoardAt = now

        var notifications: [ErrorNotification] = []
        for item in relevant {
            if var episode = episodes[item.model], !boardsWereMissing {
                // A reappearance within the recovery window continues the episode.
                episode.absentSince = nil
                episodes[item.model] = episode
            } else {
                let allowed = postedAt.count < Self.maximumPerHour
                episodes[item.model] = Episode(startNotified: allowed, absentSince: nil)
                if allowed {
                    postedAt.append(now)
                    notifications.append(Self.start(for: item))
                }
            }
        }

        let present = Set(relevant.map(\.model))
        for (model, var episode) in episodes.sorted(by: { $0.key < $1.key }) where !present.contains(model) {
            let since = episode.absentSince ?? now
            if now.timeIntervalSince(since) >= Self.recoveryWindow {
                episodes[model] = nil
                if episode.startNotified, postedAt.count < Self.maximumPerHour {
                    postedAt.append(now)
                    notifications.append(Self.recovery(of: model))
                }
            } else {
                episode.absentSince = since
                episodes[model] = episode
            }
        }
        return notifications
    }

    /// Forgets every episode and the baseline, for example when sharing or the setting is switched off.
    /// The posting times stay, so switching off and on cannot get around the hourly limit.
    public mutating func reset() {
        episodes.removeAll()
        hasBaseline = false
        lastBoardAt = nil
    }

    private static func start(for item: CommunityErrorAlerts.RelevantAlert) -> ErrorNotification {
        let body: String
        if item.ownFailure {
            body = "It’s not just you: \(CommunityErrorAlerts.contributorCount(item.otherContributors, adjective: "other")) hit provider errors on this model in the last hour."
        } else {
            let noun = item.alert.failingContributors == 1 ? "contributor" : "contributors"
            body = "\(item.alert.failingContributors) Tokrate \(noun) reported \(CommunityErrorAlerts.counts(of: item.alert)) in the last hour."
        }
        return ErrorNotification(kind: .start, model: item.model, title: "Provider errors on \(item.model)", body: body)
    }

    private static func recovery(of model: String) -> ErrorNotification {
        ErrorNotification(
            kind: .recovery, model: model, title: "\(model) looks healthy again",
            body: "Contributors no longer report provider errors on this model."
        )
    }
}
