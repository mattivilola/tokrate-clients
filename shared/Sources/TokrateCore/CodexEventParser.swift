import CoreFoundation
import CryptoKit
import Foundation

/// Reads the observed Codex JSONL event shape and emits completed-turn metrics only.
/// Message bodies, prompts, account metadata, and session identifiers are never returned.
///
/// Sessions spawned by another session (`source.subagent.thread_spawn`) are read only to report their
/// turns as delegated work (see `DelegationEvent`); they emit no metric and no live response. Every
/// other agent session is skipped.
public struct CodexEventParser: Sendable {
    private struct TurnState: Sendable {
        var startedAt: Date?
        /// True once this parser instance saw the turn's `task_started` event.
        var startObserved = false
        var outputTokens: Int?
        var reasoningOutputTokens: Int?
        /// From the latest `turn_token_usage`: input tokens including the cached ones, and the cached ones.
        var inputTokens: Int?
        var cachedInputTokens: Int?
        var durationMilliseconds: Double?
        var ttftMilliseconds: Double?
        var model: String?
        var modelWasAmbiguous = false
        var reasoningEffort: String?
        var reasoningEffortWasAmbiguous = false
        /// Qualifying API responses of the turn (see `ResponseSpeed`).
        var responseTokens = 0
        var responseSeconds = 0.0
        var responseCount = 0
        var seenResponseIDs: Set<String> = []
    }

    private var sourceIdentity: String
    private var sessionIdentity: String?
    private var turns: [String: TurnState] = [:]
    private var emittedTurnIDs: Set<String> = []
    private var isAgentSession = false
    /// Attribution key of the root session a spawned child session works for, once its metadata names one.
    private var delegatedRootKey: String?
    /// Attribution key of this session's own root, set for non-agent sessions.
    private var primaryRootKey: String?
    private var delegationEvents: [DelegationEvent] = []
    private var clientVersion: String?
    private var surface: ToolSurface?
    private var sourceKind = "unknown"
    private var provider = "unknown"
    /// Timestamp of the latest record that triggered a model request: the turn start, a user
    /// message, a tool-call output or a message from another agent.
    private var lastTriggerAt: Date?
    /// The trigger the response in progress answers, fixed when its first output item arrives.
    private var responseStartedAt: Date?
    private var completedResponses: [LiveResponse] = []
    /// Request outcomes since the last drain (see `RequestOutcome`).
    private var requestOutcomes: [RequestOutcome] = []
    /// Whether this rollout records why a turn failed (`cli_version` 0.145.0 or later): without that,
    /// its successes would be counted against failures nobody can see.
    private var recordsFailureCauses = false

    /// An agent session that is not delegated work has nothing to read at all.
    var isSkippedSession: Bool { isAgentSession && delegatedRootKey == nil }
    /// A spawned child session, read in full for its work items only.
    var isDelegatedWork: Bool { delegatedRootKey != nil }

    public init(sourceIdentity: String) {
        self.sourceIdentity = sourceIdentity
    }

    /// Clears per-file state after a truncate or rotation.
    public mutating func reset(sourceIdentity: String) {
        self.sourceIdentity = sourceIdentity
        sessionIdentity = nil
        turns.removeAll(keepingCapacity: true)
        emittedTurnIDs.removeAll(keepingCapacity: true)
        isAgentSession = false
        delegatedRootKey = nil
        primaryRootKey = nil
        clientVersion = nil
        surface = nil
        sourceKind = "unknown"
        provider = "unknown"
        lastTriggerAt = nil
        responseStartedAt = nil
        completedResponses.removeAll(keepingCapacity: true)
        requestOutcomes.removeAll(keepingCapacity: true)
        recordsFailureCauses = false
    }

    /// Qualifying responses completed since the last call.
    mutating func drainCompletedResponses() -> [LiveResponse] {
        defer { completedResponses.removeAll(keepingCapacity: true) }
        return completedResponses
    }

    /// Request outcomes recognised since the last call.
    mutating func drainRequestOutcomes() -> [RequestOutcome] {
        defer { requestOutcomes.removeAll(keepingCapacity: true) }
        return requestOutcomes
    }

    /// Delegated-work events since the last call.
    mutating func drainDelegationEvents() -> [DelegationEvent] {
        defer { delegationEvents.removeAll(keepingCapacity: true) }
        return delegationEvents
    }

    /// Consumes one complete JSONL line. Malformed, unsupported, and incomplete events are ignored.
    public mutating func consume(line: Data) -> TurnMetric? {
        guard line.count <= JSONLFileReader.maximumLineBytes,
              let root = try? JSONSerialization.jsonObject(with: line),
              let event = root as? [String: Any],
              let eventType = event["type"] as? String,
              let payload = event["payload"] as? [String: Any]
        else { return nil }

        if eventType == "session_meta" {
            if let version = payload["cli_version"] as? String, version.range(of: "^[a-zA-Z0-9._+-]{1,40}$", options: .regularExpression) != nil { clientVersion = version }
            surface = ToolSurface.codex(originator: payload["originator"] as? String)
            provider = payload["model_provider"] as? String == "openai" ? "openai" : "unknown"
            recordsFailureCauses = Self.recordsFailureCauses(cliVersion: payload["cli_version"] as? String)
            if let source = payload["source"] as? String, ["cli", "vscode", "exec", "desktop", "app"].contains(source) { sourceKind = "primary" }
            if let source = payload["source"] as? [String: Any], source["subagent"] != nil { isAgentSession = true }
            if let id = Self.identifier(payload["id"]) { sessionIdentity = id }
            if let parent = payload["parent_thread_id"] as? String, !parent.isEmpty { isAgentSession = true }
            if let path = payload["agent_path"] as? String, !path.isEmpty { isAgentSession = true }
            if let path = payload["agent_path"] as? [Any], !path.isEmpty { isAgentSession = true }
            // Children's `session_id` is the root thread; the parent thread is the fallback.
            let rootID = Self.identifier(payload["session_id"])
            if isAgentSession {
                let spawn = ((payload["source"] as? [String: Any])?["subagent"] as? [String: Any])?["thread_spawn"]
                if spawn is [String: Any], let root = rootID ?? Self.identifier(payload["parent_thread_id"]) {
                    delegatedRootKey = DelegationRoot.key(client: TurnMetric.codexClient, rawSessionID: root)
                }
            } else if let root = rootID ?? Self.identifier(payload["id"]) {
                primaryRootKey = DelegationRoot.key(client: TurnMetric.codexClient, rawSessionID: root)
            }
            return nil
        }

        if turns.count > 4096 { turns.removeAll(keepingCapacity: true) }
        if emittedTurnIDs.count > 8192 { emittedTurnIDs.removeAll(keepingCapacity: true) }

        if eventType == "turn_context" {
            guard let turnID = Self.identifier(payload["turn_id"]) else { return nil }
            var state = turns[turnID, default: TurnState()]
            updateModel(payload["model"] as? String, in: &state)
            updateReasoningEffort(payload["effort"], in: &state)
            turns[turnID] = state
            return nil
        }

        if eventType == "response_item" {
            consumeResponseItem(payload, at: parseDate(event["timestamp"]))
            return nil
        }

        if eventType == "token_usage_record" {
            guard let turnID = Self.identifier(payload["turn_id"]) else { return nil }
            var state = turns[turnID, default: TurnState()]
            consumeResponseUsage(payload, completedAt: parseDate(event["timestamp"]), turnID: turnID, state: &state)
            if let usage = payload["turn_token_usage"] as? [String: Any],
               let output = nonnegativeInteger(usage["output_tokens"]) {
                // Codex reports cumulative per-turn usage. A later record replaces the prior total.
                state.outputTokens = output
                state.reasoningOutputTokens = nonnegativeInteger(usage["reasoning_output_tokens"])
                state.inputTokens = nonnegativeInteger(usage["input_tokens"])
                state.cachedInputTokens = nonnegativeInteger(usage["cached_input_tokens"])
            }
            turns[turnID] = state
            return nil
        }

        guard eventType == "event_msg",
              let subtype = payload["type"] as? String,
              let turnID = Self.identifier(payload["turn_id"])
        else { return nil }

        let eventDate = parseDate(event["timestamp"])
        if subtype == "task_started" {
            lastTriggerAt = eventDate
            responseStartedAt = nil
            var state = turns[turnID, default: TurnState()]
            state.startObserved = true
            if state.startedAt == nil { state.startedAt = parseDate(payload["started_at"]) ?? eventDate }
            turns[turnID] = state
            if let root = delegatedRootKey, let startedAt = state.startedAt {
                delegationEvents.append(.workStarted(id: workID(turnID), root: root, startedAt: startedAt))
            }
            return nil
        }

        if subtype == "turn_aborted", delegatedRootKey != nil {
            turns.removeValue(forKey: turnID)
            delegationEvents.append(.workDiscarded(id: workID(turnID)))
            return nil
        }

        guard subtype == "task_complete" else { return nil }
        var state = turns[turnID, default: TurnState()]
        if state.startedAt == nil { state.startedAt = parseDate(payload["started_at"]) }
        if let duration = nonnegativeFiniteNumber(payload["duration_ms"]) {
            state.durationMilliseconds = duration
        }
        state.ttftMilliseconds = nonnegativeFiniteNumber(payload["time_to_first_token_ms"])

        let completedAt = parseDate(payload["completed_at"]) ?? eventDate
        recordTurnFailure(payload, turnID: turnID, state: state, at: completedAt)
        let duration = state.durationMilliseconds.map { $0 / 1_000 }
            ?? state.startedAt.flatMap { start in completedAt.map { $0.timeIntervalSince(start) } }
        // A completion whose start was never observed (the reader began mid-turn) may carry no
        // turn_context, so its model and effort would be wrong; it emits nothing.
        if delegatedRootKey != nil {
            turns.removeValue(forKey: turnID)
            // Only a complete turn with a final output total is work; the rest is discarded.
            if state.startObserved, let outputTokens = state.outputTokens, let completedAt {
                delegationEvents.append(.workFinished(id: workID(turnID), outputTokens: outputTokens, finishedAt: completedAt))
            } else {
                delegationEvents.append(.workDiscarded(id: workID(turnID)))
            }
            return nil
        }
        guard !isAgentSession,
              state.startObserved,
              !emittedTurnIDs.contains(turnID),
              let outputTokens = state.outputTokens,
              let completedAt,
              let duration,
              duration.isFinite,
              duration > 0,
              outputTokens >= 0
        else {
            turns[turnID] = state
            return nil
        }

        let ttft = state.ttftMilliseconds.map { $0 / 1_000 }
        guard ttft?.isFinite != false else {
            turns[turnID] = state
            return nil
        }
        let throughput = Double(outputTokens) / duration
        guard ResponseSpeed.isPlausibleTurnThroughput(outputTokens: outputTokens, durationSeconds: duration) else {
            turns[turnID] = state
            return nil
        }

        emittedTurnIDs.insert(turnID)
        turns.removeValue(forKey: turnID)
        let id = workID(turnID)
        if let root = primaryRootKey { delegationEvents.append(.primaryTurn(turnID: id, root: root)) }
        return TurnMetric(
            id: id,
            completedAt: completedAt,
            model: state.modelWasAmbiguous ? nil : state.model,
            outputTokens: outputTokens,
            durationSeconds: duration,
            codexTTFTSeconds: ttft,
            turnThroughputTPS: throughput,
            streamingTPS: nil,
            client: TurnMetric.codexClient,
            clientVersion: clientVersion,
            parserVersion: TurnMetric.codexParserVersion,
            metricVersion: TurnMetric.codexMetricVersion,
            reasoningOutputTokens: state.reasoningOutputTokens,
            sourceKind: sourceKind,
            provider: provider,
            reasoningEffort: state.reasoningEffortWasAmbiguous ? nil : state.reasoningEffort,
            responseOutputTokens: state.responseCount > 0 ? state.responseTokens : nil,
            responseDurationSeconds: state.responseCount > 0 ? state.responseSeconds : nil,
            responseCount: state.responseCount > 0 ? state.responseCount : nil,
            surface: surface,
            // Codex logs a cache-write field that is always 0: not reported, never 0.
            inputTokens: state.inputTokens,
            cacheReadInputTokens: state.cachedInputTokens,
            cacheWriteInputTokens: nil
        )
    }

    /// The local pseudonym of one turn: a metric id for a primary turn, a work id for a child's.
    private func workID(_ turnID: String) -> String {
        let identity = sessionIdentity ?? sourceIdentity
        return SHA256.hexDigest(of: "\(identity)|\(turnID)")
    }

    /// Session, turn and response ids are kept as dictionary keys and in digests: none may be empty
    /// or longer than `maximumIdentifierBytes`, so a 1 MiB line cannot pin that much memory.
    static let maximumIdentifierBytes = 512

    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= maximumIdentifierBytes else { return nil }
        return value
    }

    /// Tracks which record the next response answers. Model output items fix the response's start;
    /// everything that feeds the model (user messages, tool outputs, other agents) moves the trigger.
    private mutating func consumeResponseItem(_ payload: [String: Any], at date: Date?) {
        guard let type = payload["type"] as? String else { return }
        let isTrigger = switch type {
        case "message": payload["role"] as? String == "user"
        case "agent_message": true
        default: type.hasSuffix("_output")
        }
        if isTrigger {
            if let date { lastTriggerAt = date }
            return
        }
        // Developer instructions are context, not a request or a model output.
        if type == "message", payload["role"] as? String != "assistant" { return }
        if responseStartedAt == nil { responseStartedAt = lastTriggerAt }
    }

    /// One `token_usage_record` closes one API response: `usage` is that response's own usage, while
    /// `turn_token_usage` is the cumulative turn total.
    private mutating func consumeResponseUsage(_ payload: [String: Any], completedAt: Date?, turnID: String, state: inout TurnState) {
        let started = responseStartedAt ?? lastTriggerAt
        responseStartedAt = nil
        guard let completedAt,
              let responseID = Self.identifier(payload["response_id"]),
              let usage = payload["usage"] as? [String: Any],
              let tokens = nonnegativeInteger(usage["output_tokens"]),
              !state.seenResponseIDs.contains(responseID) else { return }
        // Before the response-speed filter and whether or not its start was seen: every completed
        // response is one succeeded request.
        recordSuccess(responseID: responseID, state: state, at: completedAt)
        guard let started else { return }
        if state.seenResponseIDs.count < 4_096 { state.seenResponseIDs.insert(responseID) }
        let duration = completedAt.timeIntervalSince(started)
        guard ResponseSpeed.qualifies(outputTokens: tokens, durationSeconds: duration) else { return }
        let (sum, overflow) = state.responseTokens.addingReportingOverflow(tokens)
        guard !overflow else { return }
        state.responseTokens = sum
        state.responseSeconds += duration
        state.responseCount += 1
        guard !isAgentSession, !state.modelWasAmbiguous, let model = state.model else { return }
        completedResponses.append(LiveResponse(
            id: SHA256.hexDigest(of: "response|\(sessionIdentity ?? sourceIdentity)|\(responseID)"),
            model: model,
            provider: provider,
            client: TurnMetric.codexClient,
            sourceKind: sourceKind,
            metricVersion: TurnMetric.codexMetricVersion,
            reasoningEffort: state.reasoningEffortWasAmbiguous ? nil : state.reasoningEffort,
            completedAt: completedAt,
            outputTokens: tokens,
            durationSeconds: duration
        ))
    }

    // MARK: Request outcomes

    /// The model and provider of an outcome: the turn's own model (nil when its turns disagree) and
    /// OpenAI, in a rollout that records failure causes. Sessions that are neither a primary session
    /// nor a spawned child (approval-review sessions) are not requests of the user's work.
    private func outcomeModel(of state: TurnState) -> String? {
        guard recordsFailureCauses, !isSkippedSession, provider == "openai", !state.modelWasAmbiguous else { return nil }
        return state.model
    }

    private mutating func recordSuccess(responseID: String, state: TurnState, at completedAt: Date) {
        guard let model = outcomeModel(of: state) else { return }
        append(RequestOutcome(
            dedupeKey: RequestOutcome.key(TurnMetric.codexClient, sessionIdentity ?? sourceIdentity, responseID),
            occurredAt: completedAt, client: TurnMetric.codexClient, clientVersion: clientVersion,
            parserVersion: TurnMetric.codexParserVersion, model: model, provider: provider, kind: .succeeded
        ))
    }

    /// A turn that ended with a terminal provider-side error is one failed request. Only the error's
    /// enum (and the status of the variants that carry one) is read, never its message.
    private mutating func recordTurnFailure(_ payload: [String: Any], turnID: String, state: TurnState, at completedAt: Date?) {
        guard let completedAt, let model = outcomeModel(of: state), let error = payload["error"] as? [String: Any],
              let kind = Self.failureKind(error["codex_error_info"]) else { return }
        append(RequestOutcome(
            dedupeKey: RequestOutcome.key(TurnMetric.codexClient, sessionIdentity ?? sourceIdentity, turnID, "failure"),
            occurredAt: completedAt, client: TurnMetric.codexClient, clientVersion: clientVersion,
            parserVersion: TurnMetric.codexParserVersion, model: model, provider: provider, kind: kind
        ))
    }

    private mutating func append(_ outcome: RequestOutcome?) {
        if let outcome { requestOutcomes.append(outcome) }
    }

    private static let statusVariants = ["response_too_many_failed_attempts", "http_connection_failed", "response_stream_connection_failed"]

    /// The provider-side class of a `codex_error_info` value (contract "Per-tool mapping"); nil for every
    /// other error, including a connection failure that carries no status and every 429.
    static func failureKind(_ info: Any?) -> RequestOutcome.Kind? {
        if let name = info as? String {
            return switch name {
            case "server_overloaded": .overloaded
            case "internal_server_error": .serverError
            default: nil
            }
        }
        guard let variants = info as? [String: Any] else { return nil }
        for name in statusVariants {
            guard let fields = variants[name] as? [String: Any], let status = fields["http_status_code"] as? NSNumber,
                  CFGetTypeID(status) != CFBooleanGetTypeID(), (500...599).contains(status.intValue),
                  status.doubleValue == Double(status.intValue) else { continue }
            // HTTP 529 is overloaded in every tool.
            return status.intValue == 529 ? .overloaded : .serverError
        }
        return nil
    }

    /// The first Codex release that persists terminal errors in `task_complete`.
    private static let firstVersionWithFailureCauses = (major: 0, minor: 145, patch: 0)

    /// Whether a rollout's `cli_version` is 0.145.0 or later by semantic-version order (a pre-release of
    /// 0.145.0 is earlier). A missing or unparseable version records no outcomes.
    static func recordsFailureCauses(cliVersion: String?) -> Bool {
        guard let cliVersion,
              let match = versionExpression.firstMatch(in: cliVersion, range: NSRange(cliVersion.startIndex..., in: cliVersion)),
              let major = number(match, 1, in: cliVersion), let minor = number(match, 2, in: cliVersion),
              let patch = number(match, 3, in: cliVersion) else { return false }
        let floor = firstVersionWithFailureCauses
        if (major, minor, patch) != (floor.major, floor.minor, floor.patch) {
            return (major, minor, patch) > (floor.major, floor.minor, floor.patch)
        }
        return match.range(at: 4).location == NSNotFound
    }

    private static let versionExpression = try! NSRegularExpression(
        pattern: "^([0-9]{1,6})\\.([0-9]{1,6})\\.([0-9]{1,6})(?:-([0-9A-Za-z.-]+))?(?:\\+[0-9A-Za-z.-]+)?\\z"
    )

    private static func number(_ match: NSTextCheckingResult, _ group: Int, in text: String) -> Int? {
        Range(match.range(at: group), in: text).flatMap { Int(text[$0]) }
    }

    private func updateReasoningEffort(_ value: Any?, in state: inout TurnState) {
        guard !state.reasoningEffortWasAmbiguous else { return }
        guard let value = value as? String, ReportedReasoningEffort.isAllowed(value) else {
            state.reasoningEffort = nil
            state.reasoningEffortWasAmbiguous = true
            return
        }
        if let previous = state.reasoningEffort, previous != value {
            state.reasoningEffort = nil
            state.reasoningEffortWasAmbiguous = true
        } else {
            state.reasoningEffort = value
        }
    }

    private func updateModel(_ model: String?, in state: inout TurnState) {
        guard let model, model.range(of: "^[a-zA-Z0-9._-]{1,80}$", options: .regularExpression) != nil else { return }
        if let previous = state.model, previous != model { state.modelWasAmbiguous = true }
        if state.model == nil, !state.modelWasAmbiguous { state.model = model }
    }

    private func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let value, let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double.rounded(.towardZero) == double,
              double < Double(Int.max)
        else { return nil }
        return number.intValue
    }

    private func nonnegativeFiniteNumber(_ value: Any?) -> Double? {
        guard let value, let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let result = number.doubleValue
        return result.isFinite && result >= 0 ? result : nil
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return TranscriptTimestamp.parse(string)
    }
}
