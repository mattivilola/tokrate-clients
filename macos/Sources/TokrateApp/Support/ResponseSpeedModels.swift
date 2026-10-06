import Foundation
import TokrateCore

// Pure response-speed logic: grouping keys, the live ring buffer, the live readout and the
// automatic model selection. Nothing here touches stores, files, Keychain or the network.

// MARK: - Grouping

/// Response speed is one definition across coding tools and source kinds, so its rows, live values
/// and baselines are grouped by model and provider only.
struct ResponseGroupKey: Hashable, Sendable {
    let model: String?
    /// Always normalised: a missing provider is "unknown".
    let provider: String

    init(model: String?, provider: String?) {
        self.model = model
        self.provider = provider ?? "unknown"
    }

    init(_ metric: TurnMetric) { self.init(model: metric.model, provider: metric.provider) }
    init(_ response: LiveResponse) { self.init(model: response.model, provider: response.provider) }
    init(_ cohort: ModelCohort) { self.init(model: cohort.model, provider: cohort.provider) }

    var displayModel: String { model ?? "Unknown model" }
}

// MARK: - Live readout

/// The live response-speed readout: the median of the latest few responses.
struct LiveSpeed: Equatable, Sendable {
    let medianTPS: Double
    /// How many responses the median covers (at most `LiveResponseBuffer.medianSample`).
    let responseCount: Int
    /// When the newest covered response completed.
    let latestAt: Date

    var caption: String { "last \(responseCount) \(responseCount == 1 ? "response" : "responses")" }

    func relativeCaption(now: Date) -> String {
        "\(caption) · \(RelativeTime.string(from: latestAt, now: now))"
    }
}

/// In-memory ring buffer of the latest qualifying responses. Local only: never persisted or shared.
struct LiveResponseBuffer: Sendable {
    static let capacity = 200
    /// The readout is the median of this many latest responses...
    static let medianSample = 5
    /// ...completed within this window.
    static let window: TimeInterval = 600

    private(set) var responses: [LiveResponse] = []

    mutating func append(contentsOf newResponses: [LiveResponse]) {
        guard !newResponses.isEmpty else { return }
        var known = Set(responses.map(\.id))
        for response in newResponses where known.insert(response.id).inserted { responses.append(response) }
        responses.sort { $0.completedAt > $1.completedAt }
        if responses.count > Self.capacity { responses.removeLast(responses.count - Self.capacity) }
    }

    mutating func removeAll() { responses.removeAll() }

    /// Median speed of the latest `medianSample` responses of `group` that completed in the last
    /// ten minutes; nil when there are none.
    func liveSpeed(for group: ResponseGroupKey?, now: Date) -> LiveSpeed? {
        guard let group else { return nil }
        let recent = responses
            .filter { ResponseGroupKey($0) == group && now.timeIntervalSince($0.completedAt) <= Self.window && $0.completedAt <= now }
            .prefix(Self.medianSample)
        guard let newest = recent.first, let median = MetricStats(values: recent.map(\.tokensPerSecond)).median else { return nil }
        return LiveSpeed(medianTPS: median, responseCount: recent.count, latestAt: newest.completedAt)
    }
}

// MARK: - Automatic model selection

/// Chooses which model the menu bar and popover follow in Auto mode. It reads only the live stream
/// of qualifying responses, so tiny automated check-ins never count. The clock is injected.
struct ActiveModelSelector: Sendable {
    /// The leader is the model with the most response output tokens in this window.
    static let window: TimeInterval = 600
    /// A new leader takes over only after leading continuously for this long.
    static let takeoverDelay: TimeInterval = 120

    private(set) var active: ResponseGroupKey?
    private var leader: ResponseGroupKey?
    private var leaderSince: Date?
    /// Restricts the candidates to one coding tool ("Auto within a coding tool").
    var clientRestriction: String? {
        didSet {
            guard clientRestriction != oldValue else { return }
            active = nil
            leader = nil
            leaderSince = nil
        }
    }

    init(clientRestriction: String? = nil) { self.clientRestriction = clientRestriction }

    @discardableResult
    mutating func update(responses: [LiveResponse], now: Date) -> ResponseGroupKey? {
        let window = responses.filter {
            $0.model != nil && $0.outputTokens >= ResponseSpeed.minimumOutputTokens
                && now.timeIntervalSince($0.completedAt) <= Self.window && $0.completedAt <= now
                && (clientRestriction == nil || $0.client == clientRestriction)
        }
        var tokens: [ResponseGroupKey: Int] = [:]
        var latest: [ResponseGroupKey: Date] = [:]
        for response in window {
            let key = ResponseGroupKey(response)
            tokens[key, default: 0] += response.outputTokens
            latest[key] = max(latest[key] ?? .distantPast, response.completedAt)
        }
        // Most tokens wins; the most recent response breaks a tie.
        guard let candidate = tokens.max(by: { left, right in
            left.value == right.value ? (latest[left.key] ?? .distantPast) < (latest[right.key] ?? .distantPast) : left.value < right.value
        })?.key else {
            active = nil
            leader = nil
            leaderSince = nil
            return nil
        }
        guard let current = active else {
            active = candidate
            leader = candidate
            leaderSince = now
            return candidate
        }
        if candidate == current {
            leader = candidate
            leaderSince = now
        } else {
            if leader != candidate {
                leader = candidate
                leaderSince = now
            }
            let ledLongEnough = leaderSince.map { now.timeIntervalSince($0) >= Self.takeoverDelay } ?? false
            // The active model has no qualifying response left in the window.
            let activeIsQuiet = tokens[current] == nil
            if ledLongEnough || activeIsQuiet {
                active = candidate
                leaderSince = now
            }
        }
        return active
    }
}

// MARK: - Auto selection fallback

enum AutoSelection {
    /// The cohort an Auto selection shows. With a live active model it is that model's most recent
    /// turn (primary turns preferred over subagent turns); with none it is the most recent turn that
    /// has response data, else the most recent turn.
    static func resolve(records: [TurnMetric], activeModel: ResponseGroupKey?, client: String?) -> ModelCohort? {
        let candidates = client.map { client in records.filter { $0.client == client } } ?? records
        if let activeModel {
            let matching = candidates.filter { ResponseGroupKey($0) == activeModel }
            let preferred = matching.filter { !$0.isSubagentTurn }
            if let latest = (preferred.isEmpty ? matching : preferred).max(by: { $0.completedAt < $1.completedAt }) {
                return ModelCohort(latest)
            }
        }
        let withResponse = candidates.filter { $0.responseSpeedTPS != nil }
        return (withResponse.isEmpty ? candidates : withResponse).max { $0.completedAt < $1.completedAt }.map(ModelCohort.init)
    }
}

// MARK: - Model maker (provider badge)

/// Who made the model: shown as a letter badge. Letters only, never company logos.
enum ModelMaker: Equatable, Sendable {
    case anthropic, openAI, xAI, google, unknown

    /// The model id decides first; the provider is used when the model id is not recognisable.
    init(model: String?, provider: String?) {
        let id = model?.lowercased() ?? ""
        if id.hasPrefix("claude-") { self = .anthropic }
        else if id.hasPrefix("gpt-") || id.hasPrefix("codex") || id.range(of: "^o[0-9]", options: .regularExpression) != nil { self = .openAI }
        else if id.hasPrefix("grok-") { self = .xAI }
        else if id.hasPrefix("gemini-") { self = .google }
        else {
            switch provider {
            case "anthropic": self = .anthropic
            case "openai": self = .openAI
            case "xai": self = .xAI
            case "google": self = .google
            default: self = .unknown
            }
        }
    }

    init(_ key: ResponseGroupKey?) { self.init(model: key?.model, provider: key?.provider) }

    var title: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .xAI: "xAI"
        case .google: "Google"
        case .unknown: "Unknown provider"
        }
    }

    var letter: String? {
        switch self {
        case .anthropic: "A"
        case .openAI: "O"
        case .xAI: "X"
        case .google: "G"
        case .unknown: nil
        }
    }
}
