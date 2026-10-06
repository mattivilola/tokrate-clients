import CryptoKit
import Foundation

/// One evaluated turn: the record to emit and whether its delegated total is settled.
struct OpenCodeTurnEvaluation: Sendable {
    let userMessageID: String
    let metric: TurnMetric
    /// `metric.delegatedOutputTokens` is final (the metric is then the settled record).
    let isFinal: Bool
    /// When an unsettled turn stops waiting for unfinished subagent messages.
    let settlesAt: Date?
}

/// Builds measurements from the in-memory index of OpenCode messages. Pure: no file access and no
/// clock, so the contract's rules ("OpenCode (0.1.18)") can be tested directly.
struct OpenCodeTurnBuilder: Sendable {
    static let client = "opencode"
    static let parserVersion = "opencode-db-v1"
    static let metricVersion = "opencode-observed-turn-v1"
    /// `DELEGATION_MAX_WAIT`: how long after a turn ends its unfinished subagent messages are waited for.
    static let delegationMaximumWait: TimeInterval = 30 * 60
    /// A delegated chain deeper than this is not followed (and a cycle can never loop).
    private static let maximumSessionDepth = 16

    private let sessions: [String: OpenCodeSession]
    private let messages: [OpenCodeMessage]
    private let assistantsByParent: [String: [OpenCodeMessage]]
    /// Assistant messages of subagent sessions, by the root primary session they descend from.
    private let delegatedByRoot: [String: [OpenCodeMessage]]

    init(sessions: [String: OpenCodeSession], messages: some Collection<OpenCodeMessage>) {
        self.sessions = sessions
        self.messages = Array(messages)
        var byParent: [String: [OpenCodeMessage]] = [:]
        var delegated: [String: [OpenCodeMessage]] = [:]
        var rootCache: [String: String?] = [:]
        func root(of sessionID: String) -> String? {
            if let known = rootCache[sessionID] { return known }
            var current = sessionID
            var depth = 0
            while let parent = sessions[current]?.parentID, depth < Self.maximumSessionDepth {
                current = parent
                depth += 1
            }
            // Only a chain that ends at a known primary session has a root.
            let result = sessions[current]?.isPrimary == true && current != sessionID ? current : nil
            rootCache[sessionID] = .some(result)
            return result
        }
        for message in self.messages where message.role == .assistant {
            if sessions[message.sessionID]?.isPrimary == true, let parent = message.parentID {
                byParent[parent, default: []].append(message)
            } else if let root = root(of: message.sessionID) {
                delegated[root, default: []].append(message)
            }
        }
        assistantsByParent = byParent
        delegatedByRoot = delegated
    }

    /// The turn started by each user message that is complete and measurable, skipping those in `settled`.
    func evaluations(excluding settled: Set<String>, now: Date) -> [OpenCodeTurnEvaluation] {
        messages.compactMap { message in
            guard message.role == .user, !settled.contains(message.id) else { return nil }
            return evaluate(user: message, now: now)
        }
    }

    /// Assistant messages that qualify as one response and belong to a measured (primary, supported
    /// version) session: the candidates for the live stream.
    func liveCandidates(completedSince milliseconds: Int64) -> [OpenCodeMessage] {
        messages.filter { message in
            guard message.role == .assistant, !message.failed, !message.isMalformed,
                  let completed = message.completedMs, completed >= milliseconds,
                  let seconds = message.responseDurationSeconds, let tokens = message.outputTokens,
                  let session = sessions[message.sessionID], session.isPrimary,
                  OpenCodeVersion.meetsFloor(session.version) else { return false }
            return ResponseSpeed.qualifies(outputTokens: tokens, durationSeconds: seconds)
        }
    }

    // MARK: Rules

    private func evaluate(user: OpenCodeMessage, now: Date) -> OpenCodeTurnEvaluation? {
        guard let session = sessions[user.sessionID], session.isPrimary, OpenCodeVersion.meetsFloor(session.version),
              let version = session.version, let startedMs = user.createdMs, !user.isMalformed else { return nil }
        let assistants = (assistantsByParent[user.id] ?? []).filter { $0.sessionID == user.sessionID }
        // A running, failed or unreadable step makes the turn incomplete.
        guard !assistants.isEmpty,
              assistants.allSatisfy({ $0.completed && !$0.failed && !$0.isMalformed }),
              let last = assistants.max(by: { ($0.createdMs ?? 0, $0.id) < ($1.createdMs ?? 0, $1.id) }),
              last.hasTerminalFinish,
              let completedMs = assistants.compactMap(\.completedMs).max() else { return nil }
        let duration = Double(completedMs - startedMs) / 1_000
        let outputTokens = assistants.reduce(0) { $0 + ($1.outputTokens ?? 0) }
        guard duration.isFinite, duration > 0,
              ResponseSpeed.isPlausibleTurnThroughput(outputTokens: outputTokens, durationSeconds: duration) else { return nil }

        let models = Set(assistants.map(\.model)), providers = Set(assistants.map(\.provider)), efforts = Set(assistants.map(\.effort))
        let model = models.count == 1 ? models.first.flatMap { $0 } : nil
        let provider = providers.count == 1 ? providers.first ?? "unknown" : "unknown"
        let effort = efforts.count == 1 ? efforts.first.flatMap { $0 } : nil

        let responses = assistants.filter { message in
            message.responseDurationSeconds.map { ResponseSpeed.qualifies(outputTokens: message.outputTokens ?? 0, durationSeconds: $0) } == true
        }
        let responseTokens = responses.reduce(0) { $0 + ($1.outputTokens ?? 0) }
        let responseSeconds = responses.reduce(0) { $0 + ($1.responseDurationSeconds ?? 0) }

        let completedAt = Date(timeIntervalSince1970: Double(completedMs) / 1_000)
        let delegated = delegatedOutput(session: user.sessionID, startedMs: startedMs, completedMs: completedMs, completedAt: completedAt, now: now)

        // Prompt cache: every step must report both counts, else the turn reports none of them. Only
        // Anthropic reports cache writes; other providers log 0, which is not a report.
        let cacheSteps = assistants.compactMap { message -> (input: Int, read: Int, write: Int)? in
            guard let input = message.inputTokens, let read = message.cacheReadTokens, let write = message.cacheWriteTokens else { return nil }
            return (input, read, write)
        }
        let hasCache = cacheSteps.count == assistants.count
        let digest = SHA256.hash(data: Data("opencode|\(user.sessionID)|\(user.id)".utf8))
        let metric = TurnMetric(
            id: digest.map { String(format: "%02x", $0) }.joined(),
            completedAt: completedAt,
            model: model,
            outputTokens: outputTokens,
            durationSeconds: duration,
            codexTTFTSeconds: nil,
            turnThroughputTPS: Double(outputTokens) / duration,
            streamingTPS: nil,
            client: Self.client,
            clientVersion: version,
            parserVersion: Self.parserVersion,
            metricVersion: Self.metricVersion,
            reasoningOutputTokens: assistants.reduce(0) { $0 + ($1.reasoningTokens ?? 0) },
            sourceKind: "primary",
            provider: provider,
            reasoningEffort: effort,
            responseOutputTokens: responses.isEmpty ? nil : responseTokens,
            responseDurationSeconds: responses.isEmpty ? nil : responseSeconds,
            responseCount: responses.isEmpty ? nil : responses.count,
            delegatedOutputTokens: delegated.total,
            inputTokens: hasCache ? cacheSteps.reduce(0) { $0 + $1.input + $1.read + $1.write } : nil,
            cacheReadInputTokens: hasCache ? cacheSteps.reduce(0) { $0 + $1.read } : nil,
            cacheWriteInputTokens: hasCache && provider == "anthropic" ? cacheSteps.reduce(0) { $0 + $1.write } : nil
        )
        let checked = metric.responseOutputTokens != nil && !metric.hasPlausibleResponseTiming ? metric.withoutResponseTiming() : metric
        return OpenCodeTurnEvaluation(
            userMessageID: user.id, metric: checked, isFinal: delegated.total != nil, settlesAt: delegated.settlesAt
        )
    }

    /// Output of the subagent messages created while the turn ran (contract "Delegated output"). The
    /// total is nil while any of them is still unfinished, until `delegationMaximumWait` after the turn,
    /// when unfinished ones are ignored.
    private func delegatedOutput(
        session: String, startedMs: Int64, completedMs: Int64, completedAt: Date, now: Date
    ) -> (total: Int?, settlesAt: Date?) {
        let inWindow = (delegatedByRoot[session] ?? []).filter { message in
            guard !message.isMalformed, let created = message.createdMs else { return false }
            return created >= startedMs && created <= completedMs
        }
        let finished = inWindow.filter(\.completed)
        let total = finished.reduce(0) { $0 + ($1.outputTokens ?? 0) }
        let settlesAt = completedAt.addingTimeInterval(Self.delegationMaximumWait)
        if finished.count == inWindow.count || now >= settlesAt { return (total, nil) }
        return (nil, settlesAt)
    }
}
