import CoreFoundation
import CryptoKit
import Foundation

/// Parses the `wire.jsonl` event log Kimi Code writes for each agent of a session (contract "Kimi Code
/// (0.1.21)"), from the CLI or from the Kimi desktop app. Only the record type, its time and the few
/// fields the contract lists are read; prompts, content, tool calls and results are never retained.
///
/// A step is one model call (`step.begin` to `step.end`) and a turn is the steps sharing one `turnId`.
/// In `.main` scope a turn is emitted as a `TurnMetric` at its first successful `end_turn` step end; in
/// `.subagent` scope the same turns are reported only as delegated work items.
struct KimiWireParser: JSONLMetricParser {
    enum Scope: Sendable {
        case main
        case subagent
    }

    static let client = "kimi-code"
    static let parserVersion = "kimi-wire-v1"
    static let metricVersion = "kimi-observed-turn-v1"
    /// Largest accepted value of one usage count.
    static let maximumTokenCount = 100_000_000
    /// `turn.ended` reasons and `agent.turn.ended` outcomes that end a turn without an answer.
    private static let failedTurnReasons: Set<String> = ["failed", "aborted", "cancelled", "interrupted", "error"]
    private static let failedAgentOutcomes: Set<String> = ["failed", "aborted"]
    private static let safeIdentifierScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    private struct Usage: Sendable {
        let output: Int
        let inputOther: Int
        let cacheRead: Int
        let cacheCreation: Int
    }

    /// The request that answered a step, with its values already checked: the model is nil unless it is a
    /// safe identifier, the provider is `moonshot` or `unknown`, the effort is nil unless it is reported.
    private struct Request: Sendable {
        let time: Int64
        let model: String?
        let provider: String
        let effort: String?
    }

    private struct OpenStep: Sendable {
        let number: Int
        var request: Request?
    }

    private struct Prompt: Sendable {
        let time: Int64
        /// A prompt that starts a measured turn: the user's own in `.main` scope, any in `.subagent` scope.
        let counts: Bool
    }

    private struct Turn: Sendable {
        let id: String
        /// False for a turn that cannot be measured (system-triggered, joined mid-file, failed) and once
        /// it completed: its later steps then only feed the live stream.
        var isMeasured: Bool
        let startedAt: Int64
        var openStep: OpenStep?
        var outputTokens = 0
        var inputTokens = 0
        var cacheReadTokens = 0
        var responseTokens = 0
        var responseSeconds = 0.0
        var responseCount = 0
        var models: Set<String?> = []
        var providers: Set<String> = []
        var efforts: Set<String?> = []
    }

    private let scope: Scope
    private let surface: ToolSurface
    private var sessionName: String
    private var agentName: String
    private var turn: Turn?
    private var latestPrompt: Prompt?
    private var completedResponses: [LiveResponse] = []
    private var delegationEvents: [DelegationEvent] = []

    init(sourceIdentity: String) { self.init(sourceIdentity: sourceIdentity, scope: .main, surface: .cli) }

    init(sourceIdentity: String, scope: Scope, surface: ToolSurface) {
        self.scope = scope
        self.surface = surface
        (sessionName, agentName) = Self.identity(ofFileAt: sourceIdentity)
    }

    mutating func reset(sourceIdentity: String) {
        (sessionName, agentName) = Self.identity(ofFileAt: sourceIdentity)
        dropTurn()
        latestPrompt = nil
        completedResponses.removeAll(keepingCapacity: true)
    }

    /// A tail can start inside a turn. Its first step is then not step 1, so that turn stays unmeasured
    /// by the step rule; nothing else needs to change.
    mutating func markStartedMidFile() {
        dropTurn()
        latestPrompt = nil
    }

    mutating func drainCompletedResponses() -> [LiveResponse] {
        defer { completedResponses.removeAll(keepingCapacity: true) }
        return completedResponses
    }

    mutating func drainDelegationEvents() -> [DelegationEvent] {
        defer { delegationEvents.removeAll(keepingCapacity: true) }
        return delegationEvents
    }

    mutating func consume(line: Data) -> TurnMetric? {
        guard line.count <= JSONLFileReader.maximumLineBytes,
              let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = root["type"] as? String,
              let time = Self.milliseconds(root["time"])
        else { return nil }

        switch type {
        case "turn.prompt":
            notePrompt(root, at: time)
        case "llm.request":
            noteRequest(root, at: time)
        case "context.append_loop_event":
            return consumeLoopEvent(root, at: time)
        case "turn.step.interrupted":
            discardTurn(withID: Self.turnIdentifier(root["turnId"]))
        case "turn.ended":
            if let reason = root["reason"] as? String, Self.failedTurnReasons.contains(reason) {
                discardTurn(withID: Self.turnIdentifier(root["turnId"]))
            }
        case "agent.turn.ended":
            if let outcome = root["outcome"] as? String, Self.failedAgentOutcomes.contains(outcome) {
                discardTurn(withID: Self.turnIdentifier(root["turnId"]))
            }
        case "prompt.aborted":
            // It names no turn: whichever one is open is discarded.
            discardTurn()
        default:
            break
        }
        return nil
    }

    // MARK: Records

    private mutating func notePrompt(_ root: [String: Any], at time: Int64) {
        latestPrompt = Prompt(time: time, counts: scope == .subagent || Self.isUserPrompt(root))
    }

    /// Kimi Code's own definition of a prompt the user typed: no origin, a `user` origin, or a skill or
    /// plugin command the user invoked with a slash.
    private static func isUserPrompt(_ record: [String: Any]) -> Bool {
        guard let value = record["origin"] else { return true }
        guard let origin = value as? [String: Any], let kind = origin["kind"] as? String else { return false }
        switch kind {
        case "user": return true
        case "skill_activation", "plugin_command": return origin["trigger"] as? String == "user-slash"
        default: return false
        }
    }

    private mutating func noteRequest(_ root: [String: Any], at time: Int64) {
        guard var state = turn, var open = state.openStep, root["turnStep"] as? String == "\(state.id).\(open.number)" else { return }
        let effort = (root["thinkingEffort"] as? String).flatMap { ReportedReasoningEffort.isAllowed($0) ? $0 : nil }
        // A retried call writes another request: the latest one answered.
        open.request = Request(
            time: time,
            model: (root["model"] as? String).flatMap { Self.isSafeIdentifier($0, maximum: 80) ? $0 : nil },
            provider: root["provider"] as? String == "kimi" ? "moonshot" : "unknown",
            effort: effort
        )
        state.openStep = open
        turn = state
    }

    private mutating func consumeLoopEvent(_ root: [String: Any], at time: Int64) -> TurnMetric? {
        guard let event = root["event"] as? [String: Any], let kind = event["type"] as? String,
              let turnID = Self.turnIdentifier(event["turnId"]), let step = Self.positiveInteger(event["step"])
        else { return nil }
        switch kind {
        case "step.begin":
            beginStep(turnID: turnID, step: step)
            return nil
        case "step.end":
            return endStep(turnID: turnID, step: step, event: event, at: time)
        default:
            return nil
        }
    }

    // MARK: Steps and turns

    /// A step of another turn ends the one before it: a turn that has not completed is dropped (the
    /// desktop app writes nothing for a call that failed).
    private mutating func beginStep(turnID: String, step: Int) {
        if let current = turn, current.id != turnID { dropTurn() }
        if turn != nil {
            // An open step of this turn never ended.
            if turn?.openStep != nil { discardTurn() }
            turn?.openStep = OpenStep(number: step)
        } else {
            startTurn(turnID: turnID, step: step)
        }
    }

    private mutating func startTurn(turnID: String, step: Int) {
        let prompt = latestPrompt
        latestPrompt = nil
        let measured = prompt?.counts == true && step == 1
        var state = Turn(id: turnID, isMeasured: measured, startedAt: prompt?.time ?? 0)
        state.openStep = OpenStep(number: step)
        turn = state
        if measured, scope == .subagent {
            delegationEvents.append(.workStarted(id: workID(of: state), root: rootKey, startedAt: Self.date(state.startedAt)))
        }
    }

    private mutating func endStep(turnID: String, step: Int, event: [String: Any], at time: Int64) -> TurnMetric? {
        guard var state = turn, state.id == turnID, let open = state.openStep, open.number == step else { return nil }
        state.openStep = nil
        turn = state
        let finishReason = event["finishReason"] as? String
        guard finishReason == "tool_use" || finishReason == "end_turn", let usage = Self.usage(event["usage"]),
              let request = open.request
        else {
            // A failed step, or one without the request that answered it, cannot be measured.
            discardTurn()
            return nil
        }
        let duration = Double(time - request.time) / 1_000
        let isResponse = ResponseSpeed.qualifies(outputTokens: usage.output, durationSeconds: duration)
        if isResponse, scope == .main {
            completedResponses.append(LiveResponse(
                id: SHA256.hexDigest(of: "response|\(Self.client)|\(sessionName)|\(agentName)|\(turnID)|\(step)|\(request.time)"),
                model: request.model,
                provider: request.provider,
                client: Self.client,
                sourceKind: "primary",
                metricVersion: Self.metricVersion,
                reasoningEffort: request.effort,
                completedAt: Self.date(time),
                outputTokens: usage.output,
                durationSeconds: duration
            ))
        }
        guard state.isMeasured else { return nil }
        state.outputTokens += usage.output
        state.inputTokens += usage.inputOther + usage.cacheRead + usage.cacheCreation
        state.cacheReadTokens += usage.cacheRead
        if isResponse {
            state.responseTokens += usage.output
            state.responseSeconds += duration
            state.responseCount += 1
        }
        state.models.insert(request.model)
        state.providers.insert(request.provider)
        state.efforts.insert(request.effort)
        turn = state
        return finishReason == "end_turn" ? completeTurn(at: time) : nil
    }

    /// Completes the current turn at its first `end_turn`: a `TurnMetric` in `.main` scope, a finished
    /// work item in `.subagent` scope. Its later steps belong to no measured turn.
    private mutating func completeTurn(at completedAt: Int64) -> TurnMetric? {
        guard let state = turn, state.isMeasured else { return nil }
        turn?.isMeasured = false
        let duration = Double(completedAt - state.startedAt) / 1_000
        guard duration > 0, ResponseSpeed.isPlausibleTurnThroughput(outputTokens: state.outputTokens, durationSeconds: duration) else {
            reportDiscarded(state)
            return nil
        }
        guard scope == .main else {
            delegationEvents.append(.workFinished(id: workID(of: state), outputTokens: state.outputTokens, finishedAt: Self.date(completedAt)))
            return nil
        }
        let hasResponse = state.responseCount > 0
        let metric = TurnMetric(
            id: SHA256.hexDigest(of: "\(Self.client)|\(sessionName)|\(state.id)|\(state.startedAt)"),
            completedAt: Self.date(completedAt),
            model: state.models.common,
            outputTokens: state.outputTokens,
            durationSeconds: duration,
            codexTTFTSeconds: nil,
            turnThroughputTPS: Double(state.outputTokens) / duration,
            streamingTPS: nil,
            client: Self.client,
            clientVersion: nil,
            parserVersion: Self.parserVersion,
            metricVersion: Self.metricVersion,
            sourceKind: "primary",
            provider: state.providers.count == 1 ? state.providers.first : "unknown",
            reasoningEffort: state.efforts.common,
            responseOutputTokens: hasResponse ? state.responseTokens : nil,
            responseDurationSeconds: hasResponse ? state.responseSeconds : nil,
            responseCount: hasResponse ? state.responseCount : nil,
            surface: surface,
            inputTokens: state.inputTokens,
            cacheReadInputTokens: state.cacheReadTokens
        )
        delegationEvents.append(.primaryTurn(turnID: metric.id, root: rootKey))
        return metric
    }

    /// Makes the current turn unmeasurable, or ends it without a record; its later steps still feed the
    /// live stream.
    private mutating func discardTurn() {
        guard var state = turn, state.isMeasured else { return }
        reportDiscarded(state)
        state.isMeasured = false
        turn = state
    }

    private mutating func discardTurn(withID id: String?) {
        guard let id, turn?.id == id else { return }
        discardTurn()
    }

    /// Forgets the current turn; a delegated work item that never finished is reported as discarded.
    private mutating func dropTurn() {
        if let state = turn, state.isMeasured { reportDiscarded(state) }
        turn = nil
    }

    private mutating func reportDiscarded(_ state: Turn) {
        guard scope == .subagent else { return }
        delegationEvents.append(.workDiscarded(id: workID(of: state)))
    }

    // MARK: Identity

    private var rootKey: String { DelegationRoot.key(client: Self.client, rawSessionID: sessionName) }

    /// A work item's id: the agent folder keeps it apart from the main agent's turns and other subagents.
    private func workID(of state: Turn) -> String {
        SHA256.hexDigest(of: "\(Self.client)-subagent|\(sessionName)|\(agentName)|\(state.id)|\(state.startedAt)")
    }

    /// The session folder and agent folder of `<session>/agents/<agent>/wire.jsonl`.
    private static func identity(ofFileAt path: String) -> (session: String, agent: String) {
        let parts = URL(fileURLWithPath: path).pathComponents
        guard parts.count >= 5 else { return (path, "") }
        return (parts[parts.count - 4], parts[parts.count - 2])
    }

    // MARK: Values

    private static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1_000) }

    /// A finite, non-negative integer `time` in milliseconds.
    private static func milliseconds(_ value: Any?) -> Int64? {
        guard let value = integer(value), value < 1_000_000_000_000_000 else { return nil }
        return Int64(value)
    }

    private static func positiveInteger(_ value: Any?) -> Int? {
        integer(value).flatMap { $0 > 0 ? $0 : nil }
    }

    /// A turn id is a string in step events and a number in turn-end records.
    private static func turnIdentifier(_ value: Any?) -> String? {
        if let text = value as? String { return isSafeIdentifier(text, maximum: 120) ? text : nil }
        return integer(value).map(String.init)
    }

    private static func usage(_ value: Any?) -> Usage? {
        guard let fields = value as? [String: Any],
              let output = count(fields["output"]), let inputOther = count(fields["inputOther"]),
              let cacheRead = count(fields["inputCacheRead"]), let cacheCreation = count(fields["inputCacheCreation"])
        else { return nil }
        return Usage(output: output, inputOther: inputOther, cacheRead: cacheRead, cacheCreation: cacheCreation)
    }

    private static func count(_ value: Any?) -> Int? {
        integer(value).flatMap { $0 <= maximumTokenCount ? $0 : nil }
    }

    /// A JSON number (never a boolean) that is a non-negative whole number.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double.rounded(.towardZero) == double, double < Double(Int.max) else { return nil }
        return number.intValue
    }

    private static func isSafeIdentifier(_ value: String, maximum: Int) -> Bool {
        (1...maximum).contains(value.count) && value.unicodeScalars.allSatisfy(safeIdentifierScalars.contains)
    }
}

private extension Set where Element == String? {
    /// The one value every member agrees on; nil when they differ or none is known.
    var common: String? { count == 1 ? first.flatMap { $0 } : nil }
}
