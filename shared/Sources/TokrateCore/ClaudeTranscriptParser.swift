import CoreFoundation
import CryptoKit
import Foundation

/// Parses complete Claude Code user turns from either a primary transcript or a subagent transcript.
/// Transcript text is inspected only to reject tool-results and interruption markers and is never
/// retained in a metric or shared sample.
///
/// A turn runs from a human prompt to the terminal assistant message. A human message that arrives
/// while the turn is still active (Claude Code appends it as an ordinary user record) continues the
/// turn when it follows the latest activity within `maximumInterjectionGap`; otherwise it starts a
/// new turn. An interruption marker discards the turn, and client-generated `<synthetic>` assistant
/// messages invalidate it.
struct ClaudeTranscriptParser: JSONLMetricParser {
    enum Scope: Sendable {
        case primary
        case subagent
    }

    static let parserVersion = "claude-transcript-v4"
    static let primaryMetricVersion = "claude-observed-turn-v1"
    static let subagentMetricVersion = "claude-observed-subagent-turn-v1"
    static let maximumInterjectionGap: TimeInterval = 30 * 60
    private static let syntheticModel = "<synthetic>"
    private static let interruptionPrefix = "[Request interrupted by user"

    /// Turn accounting for one API message (every record sharing a `message.id`).
    private struct MessageUsage: Sendable {
        var outputTokens: Int?
        /// Prompt-cache usage of the message (contract "Prompt cache"). Records repeated for one
        /// `message.id` carry identical values, so each is taken once, from the first record that has it.
        /// `input_tokens` excludes cached tokens.
        var inputTokens: Int?
        var cacheReadInputTokens: Int?
        var cacheCreationInputTokens: Int?
        /// Timestamp of the message's latest assistant record.
        var endedAt: Date?
    }

    /// The API response being timed, independent of any turn: the live stream times responses
    /// file-wide, while a turn counts only the responses that began inside it.
    private struct ResponseTrack: Sendable {
        let id: String
        /// The latest user-type record before the response's first record.
        let startedAt: Date?
        var endedAt: Date?
        var outputTokens: Int?
        var model: String?
        var provider: String?
        var effort: String?
        /// The latest record carries a stop reason: the response is complete in live files.
        var hasStopReason = false
        /// The latest record's last content block is `thinking`: a text block may still follow.
        var endsInThinking = false
        /// The turn the response began in, when there was one.
        let turnID: String?
        let sessionID: String?
        let agentID: String?
    }

    private struct TurnState: Sendable {
        let startedAt: Date
        let userTurnID: String
        let sessionID: String?
        let agentID: String?
        var lastActivityAt: Date
        var messages: [String: MessageUsage] = [:]
        /// Set once a record carries a terminal stop reason. The turn is then pending: further records
        /// of that message still extend it, and it closes by the rules on `closeOpenResponse`.
        var terminalMessageID: String?
        var responseTokens = 0
        var responseSeconds = 0.0
        var responseCount = 0
        /// Bedrock inference-profile regions seen across the turn's counted records.
        var regions: Set<String> = []
        var hasIncompleteUsage = false
        var hasModellessMessage = false
        var hasSyntheticMessage = false
        var model: String?
        var modelIsAmbiguous = false
        /// Distinct provider evidence across the turn's counted assistant records.
        var providers: Set<String> = []
        var hasRecordWithoutProviderEvidence = false
        var clientVersion: String?
        var versionIsAmbiguous = false
        /// First non-empty `entrypoint` of the turn's records, as its category.
        var surface: ToolSurface?
        var reasoningEffort: String?
        var effortIsAmbiguous = false
    }

    private let scope: Scope
    private var sourceIdentity: String
    private var turn: TurnState?
    private var emittedUserTurnIDs: Set<String> = []
    private var completedResponses: [LiveResponse] = []
    /// Delegated-work lifecycle events since the last drain: a primary scope reports each emitted turn's
    /// root session; a subagent scope reports each turn as one delegated work item.
    private var delegationEvents: [DelegationEvent] = []
    /// Timestamp of the latest user-type record (human prompt, tool result, notification or meta
    /// record): the request for the next response is sent after it.
    private var lastTriggerAt: Date?
    private var openResponse: ResponseTrack?
    /// uuid → timestamp of the latest accepted records of this file (any type), bounded; the parent
    /// of a response's first assistant record is its request trigger.
    private var recordTimestamps: [String: Date] = [:]
    private var recordOrder: [String] = []
    static let maximumRememberedRecords = 4_096
    private var finalizedMessageIDs: Set<String> = []
    /// The poll clock reading when the open response was first seen pending (stop reason present).
    private var pendingSince: Date?
    /// A pending thinking-last message waits this long for its text block before it closes.
    static let pendingTimeout: TimeInterval = 30
    /// False while a reader that started mid-file has not yet reached a reliable turn boundary.
    private var isSynchronised = true

    init(sourceIdentity: String) { self.init(sourceIdentity: sourceIdentity, scope: .primary) }

    init(sourceIdentity: String, scope: Scope) {
        self.sourceIdentity = sourceIdentity
        self.scope = scope
    }

    mutating func reset(sourceIdentity: String) {
        self.sourceIdentity = sourceIdentity
        dropTurn()
        isSynchronised = true
        emittedUserTurnIDs.removeAll(keepingCapacity: true)
        completedResponses.removeAll(keepingCapacity: true)
        lastTriggerAt = nil
        openResponse = nil
        recordTimestamps.removeAll(keepingCapacity: true)
        recordOrder.removeAll(keepingCapacity: true)
        finalizedMessageIDs.removeAll(keepingCapacity: true)
        pendingSince = nil
    }

    /// A reader that starts mid-file can see the end of a turn whose start it never saw. Until the
    /// first terminal assistant record or a conversation-root prompt (`parentUuid` null), prompts
    /// are ignored so no partial turn is measured.
    mutating func markStartedMidFile() {
        dropTurn()
        isSynchronised = false
    }

    /// A response that carries its stop reason is waiting to be closed.
    var hasPendingWork: Bool { openResponse?.hasStopReason == true }

    mutating func consume(line: Data) -> TurnMetric? {
        guard line.count <= JSONLFileReader.maximumLineBytes,
              let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = root["type"] as? String,
              isAcceptedRecord(root)
        else { return nil }

        if emittedUserTurnIDs.count > 8_192 { emittedUserTurnIDs.removeAll(keepingCapacity: true) }
        // A terminal message can still receive records (for example text after thinking), so its turn
        // closes at the first accepted record that is not one of them.
        rememberRecord(root)
        var closed: TurnMetric?
        if let terminalID = turn?.terminalMessageID {
            let message = root["message"] as? [String: Any]
            let continues = type == "assistant" && message?["id"] as? String == terminalID
            if !continues { closed = closeTurn() }
        }
        switch type {
        case "user":
            consumeUser(root)
        case "assistant":
            consumeAssistant(root)
        default:
            break
        }
        return closed
    }

    /// `attachment.type` values of records Claude Code writes when a response arrives, not when its
    /// request is sent: `deferred_tools_record` shares its millisecond with the response's first
    /// assistant record, which names it as parent. Treating it as the request trigger collapses the
    /// response duration (real data: 336 tokens in 0.002 s, 167,992 tok/s), so such a record is
    /// remembered under its own parent's timestamp instead.
    static let bookkeepingAttachmentTypes: Set<String> = ["deferred_tools_record"]

    private mutating func rememberRecord(_ root: [String: Any]) {
        guard let uuid = safeIdentifier(root["uuid"] as? String, maximum: 120), var timestamp = parseDate(root["timestamp"]) else { return }
        if root["type"] as? String == "attachment",
           let attachmentType = (root["attachment"] as? [String: Any])?["type"] as? String,
           Self.bookkeepingAttachmentTypes.contains(attachmentType) {
            // It inherits its parent's time; a parent this file never showed leaves no trigger at all.
            guard let parent = safeIdentifier(root["parentUuid"] as? String, maximum: 120),
                  let parentAt = recordTimestamps[parent] else { return }
            timestamp = parentAt
        }
        if recordTimestamps.updateValue(timestamp, forKey: uuid) == nil {
            recordOrder.append(uuid)
            if recordOrder.count > Self.maximumRememberedRecords {
                let overflow = recordOrder.count - Self.maximumRememberedRecords
                for key in recordOrder.prefix(overflow) { recordTimestamps.removeValue(forKey: key) }
                recordOrder.removeFirst(overflow)
            }
        }
    }

    /// The request trigger of a response whose first assistant record is `root`: its parent record
    /// when this file showed it and it was written no later than the response; otherwise the latest
    /// user-type record.
    private func requestStart(for root: [String: Any], at timestamp: Date?) -> Date? {
        if let parent = safeIdentifier(root["parentUuid"] as? String, maximum: 120),
           let parentAt = recordTimestamps[parent], let timestamp, parentAt <= timestamp {
            return parentAt
        }
        return lastTriggerAt
    }

    /// Called when a reader is caught up with its file at the end of a poll. A response whose latest
    /// record carries a stop reason closes now unless its last block is `thinking`, in which case the
    /// text block may still follow: it waits up to `pendingTimeout` seconds of poll clock. A final
    /// read (archive, CLI) closes it unconditionally. Closing a terminal message emits its turn.
    mutating func pollEnded(now: Date, isFinal: Bool) -> TurnMetric? {
        guard let open = openResponse, open.hasStopReason else {
            pendingSince = nil
            return nil
        }
        if !isFinal {
            guard !open.endsInThinking else {
                let since = pendingSince ?? now
                pendingSince = since
                guard now.timeIntervalSince(since) >= Self.pendingTimeout else { return nil }
                return closeOpenResponse()
            }
        }
        return closeOpenResponse()
    }

    /// Finishes the open response; when it is the pending turn's terminal message, emits the turn.
    private mutating func closeOpenResponse() -> TurnMetric? {
        pendingSince = nil
        if let terminalID = turn?.terminalMessageID, openResponse?.id == terminalID { return closeTurn() }
        finalizeOpenResponse()
        return nil
    }

    mutating func drainCompletedResponses() -> [LiveResponse] {
        defer { completedResponses.removeAll(keepingCapacity: true) }
        return completedResponses
    }

    mutating func drainDelegationEvents() -> [DelegationEvent] {
        defer { delegationEvents.removeAll(keepingCapacity: true) }
        return delegationEvents
    }

    /// The attribution key of the session this turn belongs to; nil when the records name none.
    private func rootKey(of state: TurnState) -> String? {
        state.sessionID.map { DelegationRoot.key(client: "claude-code", rawSessionID: $0) }
    }

    /// Abandons the active turn. A subagent turn is a delegated work item that will never finish.
    private mutating func dropTurn() {
        if let state = turn { reportDiscarded(state) }
        turn = nil
    }

    private mutating func reportDiscarded(_ state: TurnState) {
        guard scope == .subagent, state.sessionID != nil else { return }
        delegationEvents.append(.workDiscarded(id: identityDigest(for: state)))
    }

    private mutating func consumeUser(_ root: [String: Any]) {
        // Any user-type record is a trigger: the next request is sent after it.
        if let triggered = parseDate(root["timestamp"]) { lastTriggerAt = max(lastTriggerAt ?? triggered, triggered) }
        guard let content = (root["message"] as? [String: Any])?["content"],
              let timestamp = parseDate(root["timestamp"])
        else { return }
        let origin = root["origin"] as? [String: Any]
        let originKind = origin?["kind"] as? String
        // A subagent's follow-up task prompt (SendMessage to a running subagent) arrives as a meta
        // record with origin `coordinator`; it is the only meta record that is a prompt.
        let isCoordinatorFollowUp = scope == .subagent && originKind == "coordinator"
        let promptKinds: Set<String> = scope == .subagent ? ["human", "coordinator"] : ["human"]
        if root["isMeta"] as? Bool == true, !isCoordinatorFollowUp { return }
        if containsToolResult(content) {
            noteActivity(at: timestamp)
            return
        }
        // Current Claude Code marks prompts with `origin`. Any other kind (for example background
        // task notifications) is activity, never a prompt. Records without `origin` come from older
        // Claude Code versions and follow the v2 rules.
        if origin != nil, !(originKind.map(promptKinds.contains) ?? false) {
            noteActivity(at: timestamp)
            return
        }
        if isInterruption(content) {
            // A response that was still streaming is cut off and never reported; a complete one is final.
            if openResponse?.hasStopReason == true { finalizeOpenResponse() } else { openResponse = nil }
            dropTurn()
            return
        }
        if !isSynchronised {
            guard root["parentUuid"] is NSNull else { return }
            isSynchronised = true
        }
        if var state = turn, timestamp.timeIntervalSince(state.lastActivityAt) <= Self.maximumInterjectionGap {
            state.lastActivityAt = max(state.lastActivityAt, timestamp)
            turn = state
            return
        }
        dropTurn()
        guard let userID = safeIdentifier(root["uuid"] as? String, maximum: 120),
              !emittedUserTurnIDs.contains(userID)
        else { return }
        var state = TurnState(
            startedAt: timestamp,
            userTurnID: userID,
            sessionID: safeIdentifier(root["sessionId"] as? String, maximum: 120),
            agentID: scope == .subagent ? safeIdentifier(root["agentId"] as? String, maximum: 120) : nil,
            lastActivityAt: timestamp
        )
        if let version = validatedVersion(root["version"]) { state.clientVersion = version }
        state.surface = ToolSurface.claude(entrypoint: root["entrypoint"] as? String)
        updateEffort(root, message: nil, in: &state)
        turn = state
        if scope == .subagent, let rootKey = rootKey(of: state) {
            delegationEvents.append(.workStarted(id: identityDigest(for: state), root: rootKey, startedAt: timestamp))
        }
    }

    private mutating func consumeAssistant(_ root: [String: Any]) {
        let stopReason = (root["message"] as? [String: Any])?["stop_reason"] as? String
        let isTerminal = stopReason == "end_turn" || stopReason == "stop_sequence"
        if !isSynchronised, isTerminal { isSynchronised = true }
        guard let message = root["message"] as? [String: Any] else { return }
        let timestamp = parseDate(root["timestamp"])

        if message["model"] as? String == Self.syntheticModel {
            // Anything before this record is a different response, and it is complete.
            finalizeOpenResponse()
            if var state = turn {
                if let timestamp { state.lastActivityAt = max(state.lastActivityAt, timestamp) }
                state.hasSyntheticMessage = true
                if isTerminal {
                    reportDiscarded(state)
                    turn = nil
                } else {
                    turn = state
                }
            }
            return
        }
        let messageID = safeIdentifier(message["id"] as? String, maximum: 120)
        if openResponse?.id != messageID { finalizeOpenResponse() }
        if let messageID { trackResponse(messageID, root: root, message: message, timestamp: timestamp, stopReason: stopReason) }
        guard var state = turn else { return }

        if let timestamp { state.lastActivityAt = max(state.lastActivityAt, timestamp) }
        if let sessionID = safeIdentifier(root["sessionId"] as? String, maximum: 120),
           let original = state.sessionID, sessionID != original {
            state.hasIncompleteUsage = true
        }
        if scope == .subagent, safeIdentifier(root["agentId"] as? String, maximum: 120) != state.agentID {
            state.hasIncompleteUsage = true
        }
        if let version = validatedVersion(root["version"]) {
            if let old = state.clientVersion, old != version { state.versionIsAmbiguous = true }
            else if state.clientVersion == nil { state.clientVersion = version }
        }
        if state.surface == nil { state.surface = ToolSurface.claude(entrypoint: root["entrypoint"] as? String) }
        updateEffort(root, message: message, in: &state)

        guard let messageID else {
            state.hasIncompleteUsage = true
            turn = state
            return
        }
        if state.messages[messageID] == nil && state.messages.count >= 4_096 {
            state.hasIncompleteUsage = true
            turn = state
            return
        }

        let provider = ClaudeProviderEvidence.provider(messageID: message["id"] as? String, requestID: root["requestId"] as? String)
        if let provider {
            state.providers.insert(provider)
        } else {
            state.hasRecordWithoutProviderEvidence = true
        }
        let rawModel = message["model"] as? String
        if let model = safeIdentifier(ClaudeModelID.normalized(rawModel), maximum: 80) {
            if let existing = state.model, existing != model { state.modelIsAmbiguous = true }
            else if state.model == nil { state.model = model }
        } else {
            state.hasModellessMessage = true
        }
        state.regions.insert(ClaudeModelID.bedrockRegion(rawModel) ?? "unknown")

        let usageFields = message["usage"] as? [String: Any]
        let output = nonnegativeInteger(usageFields?["output_tokens"])
        var usage = state.messages[messageID] ?? MessageUsage()
        if let prior = usage.outputTokens, let output, output < prior { state.hasIncompleteUsage = true }
        if let output, usage.outputTokens.map({ output >= $0 }) ?? true { usage.outputTokens = output }
        if usage.inputTokens == nil { usage.inputTokens = nonnegativeInteger(usageFields?["input_tokens"]) }
        if usage.cacheReadInputTokens == nil { usage.cacheReadInputTokens = nonnegativeInteger(usageFields?["cache_read_input_tokens"]) }
        if usage.cacheCreationInputTokens == nil { usage.cacheCreationInputTokens = nonnegativeInteger(usageFields?["cache_creation_input_tokens"]) }
        if let timestamp { usage.endedAt = max(usage.endedAt ?? timestamp, timestamp) } else { usage.endedAt = nil }
        state.messages[messageID] = usage
        if isTerminal { state.terminalMessageID = messageID }
        turn = state
    }

    /// Times the response `messageID` belongs to. The start is fixed by its first record.
    private mutating func trackResponse(_ messageID: String, root: [String: Any], message: [String: Any], timestamp: Date?, stopReason: String?) {
        guard !finalizedMessageIDs.contains(messageID) else { return }
        let output = nonnegativeInteger((message["usage"] as? [String: Any])?["output_tokens"])
        let blocks = message["content"] as? [[String: Any]]
        var track = openResponse ?? ResponseTrack(
            id: messageID,
            startedAt: requestStart(for: root, at: timestamp),
            turnID: turn?.userTurnID,
            sessionID: safeIdentifier(root["sessionId"] as? String, maximum: 120) ?? turn?.sessionID,
            agentID: scope == .subagent ? safeIdentifier(root["agentId"] as? String, maximum: 120) : nil
        )
        if let output, track.outputTokens.map({ output >= $0 }) ?? true { track.outputTokens = output }
        if let timestamp { track.endedAt = max(track.endedAt ?? timestamp, timestamp) } else { track.endedAt = nil }
        track.model = safeIdentifier(ClaudeModelID.normalized(message["model"] as? String), maximum: 80)
        track.provider = ClaudeProviderEvidence.provider(messageID: message["id"] as? String, requestID: root["requestId"] as? String) ?? "unknown"
        track.effort = (root["perTurnEffort"] ?? root["effort"] ?? message["perTurnEffort"] ?? message["effort"]).flatMap { value in
            (value as? String).flatMap { ReportedReasoningEffort.isAllowed($0) ? $0 : nil }
        }
        track.hasStopReason = stopReason != nil
        track.endsInThinking = blocks?.last?["type"] as? String == "thinking"
        openResponse = track
    }

    /// Completes the response in progress. A qualifying one joins the live stream and, when it began
    /// inside the active turn, that turn's response totals.
    private mutating func finalizeOpenResponse() {
        guard let track = openResponse else { return }
        openResponse = nil
        pendingSince = nil
        if finalizedMessageIDs.count > 8_192 { finalizedMessageIDs.removeAll(keepingCapacity: true) }
        finalizedMessageIDs.insert(track.id)
        guard let tokens = track.outputTokens, let start = track.startedAt, let end = track.endedAt else { return }
        let duration = end.timeIntervalSince(start)
        guard ResponseSpeed.qualifies(outputTokens: tokens, durationSeconds: duration) else { return }
        if var state = turn, let turnID = track.turnID, state.userTurnID == turnID {
            let (sum, overflow) = state.responseTokens.addingReportingOverflow(tokens)
            if overflow {
                state.hasIncompleteUsage = true
            } else {
                state.responseTokens = sum
                state.responseSeconds += duration
                state.responseCount += 1
            }
            turn = state
        }
        completedResponses.append(LiveResponse(
            id: "\(track.sessionID ?? sourceIdentity)|\(track.agentID ?? "")|\(track.id)",
            model: track.model,
            provider: track.provider ?? "unknown",
            client: "claude-code",
            sourceKind: scope == .subagent ? "subagent" : "primary",
            metricVersion: scope == .subagent ? Self.subagentMetricVersion : Self.primaryMetricVersion,
            reasoningEffort: track.effort,
            completedAt: end,
            outputTokens: tokens,
            durationSeconds: duration
        ))
    }

    /// Emits the pending turn once its terminal message is complete, and reports it to the delegation
    /// side channel: a finished work item (subagent scope) or a primary turn with its root session.
    private mutating func closeTurn() -> TurnMetric? {
        finalizeOpenResponse()
        guard let state = turn, let terminalID = state.terminalMessageID else { return nil }
        turn = nil
        guard let metric = makeMetric(from: state, terminalID: terminalID) else {
            reportDiscarded(state)
            return nil
        }
        if let rootKey = rootKey(of: state) {
            delegationEvents.append(scope == .subagent
                ? .workFinished(id: metric.id, outputTokens: metric.outputTokens, finishedAt: metric.completedAt)
                : .primaryTurn(turnID: metric.id, root: rootKey))
        }
        return metric
    }

    private mutating func makeMetric(from state: TurnState, terminalID: String) -> TurnMetric? {
        guard !state.hasSyntheticMessage,
              !state.hasIncompleteUsage,
              !state.messages.isEmpty,
              state.messages.values.allSatisfy({ $0.outputTokens != nil }),
              let completedAt = state.messages[terminalID]?.endedAt,
              completedAt > state.startedAt
        else { return nil }

        var total = 0
        for messageUsage in state.messages.values {
            let (sum, overflow) = total.addingReportingOverflow(messageUsage.outputTokens ?? 0)
            guard !overflow else { return nil }
            total = sum
        }
        let duration = completedAt.timeIntervalSince(state.startedAt)
        guard duration.isFinite, duration > 0 else { return nil }
        guard ResponseSpeed.isPlausibleTurnThroughput(outputTokens: total, durationSeconds: duration) else { return nil }
        let throughput = Double(total) / duration
        emittedUserTurnIDs.insert(state.userTurnID)
        let provider = state.hasRecordWithoutProviderEvidence || state.providers.count != 1
            ? "unknown" : state.providers.first ?? "unknown"
        let hasResponse = state.responseCount > 0
        let promptCache = Self.promptCache(of: state.messages.values)
        return TurnMetric(
            id: identityDigest(for: state),
            completedAt: completedAt,
            model: state.modelIsAmbiguous || state.hasModellessMessage ? nil : state.model,
            outputTokens: total,
            durationSeconds: duration,
            codexTTFTSeconds: nil,
            turnThroughputTPS: throughput,
            streamingTPS: nil,
            client: "claude-code",
            clientVersion: state.versionIsAmbiguous ? nil : state.clientVersion,
            parserVersion: Self.parserVersion,
            metricVersion: scope == .subagent ? Self.subagentMetricVersion : Self.primaryMetricVersion,
            sourceKind: scope == .subagent ? "subagent" : "primary",
            provider: provider,
            reasoningEffort: state.effortIsAmbiguous ? nil : state.reasoningEffort,
            responseOutputTokens: hasResponse ? state.responseTokens : nil,
            responseDurationSeconds: hasResponse ? state.responseSeconds : nil,
            responseCount: hasResponse ? state.responseCount : nil,
            providerRegion: provider == "amazon-bedrock" ? (state.regions.count == 1 ? state.regions.first : "unknown") : nil,
            surface: state.surface,
            inputTokens: promptCache?.input,
            cacheReadInputTokens: promptCache?.read,
            cacheWriteInputTokens: promptCache?.write
        )
    }

    /// Prompt-cache totals over the turn's counted messages: the input total includes cached tokens
    /// (`input_tokens` excludes them). Any message missing one of the three counts, or an overflow,
    /// leaves the whole set unreported: a missing count is not zero.
    private static func promptCache(of messages: Dictionary<String, MessageUsage>.Values) -> (input: Int, read: Int, write: Int)? {
        var input = 0, read = 0, write = 0
        for message in messages {
            guard let uncached = message.inputTokens, let cached = message.cacheReadInputTokens,
                  let created = message.cacheCreationInputTokens else { return nil }
            let (messageInput, firstOverflow) = uncached.addingReportingOverflow(cached)
            let (messageTotal, secondOverflow) = messageInput.addingReportingOverflow(created)
            let (newInput, inputOverflow) = input.addingReportingOverflow(messageTotal)
            let (newRead, readOverflow) = read.addingReportingOverflow(cached)
            let (newWrite, writeOverflow) = write.addingReportingOverflow(created)
            guard !(firstOverflow || secondOverflow || inputOverflow || readOverflow || writeOverflow) else { return nil }
            input = newInput
            read = newRead
            write = newWrite
        }
        return (input, read, write)
    }

    private mutating func noteActivity(at timestamp: Date) {
        guard var state = turn else { return }
        state.lastActivityAt = max(state.lastActivityAt, timestamp)
        turn = state
    }

    /// Subagent digests include the agent ID so they can never collide with primary turn digests.
    private func identityDigest(for state: TurnState) -> String {
        let identity = state.sessionID ?? sourceIdentity
        let material = scope == .subagent
            ? "\(identity)|\(state.agentID ?? "")|\(state.userTurnID)"
            : "\(identity)|\(state.userTurnID)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func isAcceptedRecord(_ event: [String: Any]) -> Bool {
        guard event["userType"] as? String == "external" else { return false }
        switch scope {
        case .primary:
            return event["isSidechain"] as? Bool == false && event["agentId"] == nil
        case .subagent:
            return event["isSidechain"] as? Bool == true
                && safeIdentifier(event["agentId"] as? String, maximum: 120) != nil
        }
    }

    private func isInterruption(_ content: Any) -> Bool {
        if let text = content as? String { return text.hasPrefix(Self.interruptionPrefix) }
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { ($0["type"] as? String) == "text" && ($0["text"] as? String)?.hasPrefix(Self.interruptionPrefix) == true }
    }

    private func containsToolResult(_ content: Any) -> Bool {
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { $0["type"] as? String == "tool_result" }
    }

    private func updateEffort(_ event: [String: Any], message: [String: Any]?, in state: inout TurnState) {
        let raw = event["perTurnEffort"] ?? event["effort"] ?? message?["perTurnEffort"] ?? message?["effort"]
        guard let raw else { return }
        guard let value = raw as? String, ReportedReasoningEffort.isAllowed(value) else {
            state.effortIsAmbiguous = true
            state.reasoningEffort = nil
            return
        }
        if let previous = state.reasoningEffort, previous != value {
            state.effortIsAmbiguous = true
            state.reasoningEffort = nil
        } else if !state.effortIsAmbiguous {
            state.reasoningEffort = value
        }
    }

    private func validatedVersion(_ value: Any?) -> String? {
        safeIdentifier(value as? String, maximum: 40, pattern: "^[a-zA-Z0-9.+_-]{1,40}$")
    }

    private func safeIdentifier(_ value: String?, maximum: Int, pattern: String = "^[a-zA-Z0-9._-]{1,120}$") -> String? {
        guard let value, value.count <= maximum, value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return value
    }

    private func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let value, let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double.rounded(.towardZero) == double, double < Double(Int.max) else { return nil }
        return number.intValue
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// Explicit routing evidence in Claude Code transcripts. Provider is never inferred from the model
/// name. The patterns use `\z` so a trailing newline cannot satisfy them (matching the Rust client).
enum ClaudeProviderEvidence {
    private static let bedrockMessage = try! NSRegularExpression(pattern: "^msg_bdrk_[A-Za-z0-9]{8,64}\\z")
    private static let vertexMessage = try! NSRegularExpression(pattern: "^msg_vrtx_[A-Za-z0-9]{8,64}\\z")
    private static let anthropicMessage = try! NSRegularExpression(pattern: "^msg_01[A-Za-z0-9]{22}\\z")
    private static let anthropicRequest = try! NSRegularExpression(pattern: "^req_[A-Za-z0-9]{20,40}\\z")

    /// The provider evidenced by one assistant record, or nil when the record carries none.
    /// Anthropic's first-party API needs both the `msg_01…` message ID and a `req_…` request ID.
    static func provider(messageID: String?, requestID: String?) -> String? {
        guard let messageID else { return nil }
        if matches(bedrockMessage, messageID) { return "amazon-bedrock" }
        if matches(vertexMessage, messageID) { return "google-vertex" }
        if matches(anthropicMessage, messageID), let requestID, matches(anthropicRequest, requestID) { return "anthropic" }
        return nil
    }

    private static func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
        expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}

/// Maps Bedrock (`us.anthropic.claude-…-v1:0`) and Vertex (`claude-…@20250929`) model identifiers to
/// the canonical Claude model ID. Anything else is returned unchanged, so ARNs and other unsafe
/// values still fail the later safe-identifier check and stay unknown.
enum ClaudeModelID {
    private static let bedrock = try! NSRegularExpression(
        pattern: "^(?:[a-z]{2,6}(?:-[a-z]+)?\\.)?anthropic\\.(claude-[a-z0-9.-]+?)(?:-v[0-9]+(?::[0-9]+)?)?\\z"
    )
    private static let vertex = try! NSRegularExpression(pattern: "^(claude-[a-z0-9.-]+)@([0-9]{8})\\z")

    private static let bedrockPrefix = try! NSRegularExpression(pattern: "^([a-z]{2,6}(?:-[a-z]+)?)\\.anthropic\\.claude-")
    private static let bedrockRegions: Set<String> = ["us", "eu", "apac", "global", "jp", "au", "ca", "us-gov"]

    /// The inference-profile region that `normalized` strips from a Bedrock model ID: the prefix when
    /// it is a known region, `unknown` for a Bedrock ID without or with an unrecognised prefix, and
    /// nil for any other model ID.
    static func bedrockRegion(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let range = NSRange(raw.startIndex..., in: raw)
        if let match = bedrockPrefix.firstMatch(in: raw, range: range), let prefix = Range(match.range(at: 1), in: raw) {
            let region = String(raw[prefix])
            return bedrockRegions.contains(region) ? region : "unknown"
        }
        return raw.hasPrefix("anthropic.claude-") ? "unknown" : nil
    }

    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let range = NSRange(raw.startIndex..., in: raw)
        if let match = bedrock.firstMatch(in: raw, range: range), let name = Range(match.range(at: 1), in: raw) {
            return String(raw[name])
        }
        if let match = vertex.firstMatch(in: raw, range: range),
           let name = Range(match.range(at: 1), in: raw), let date = Range(match.range(at: 2), in: raw) {
            return "\(raw[name])-\(raw[date])"
        }
        return raw
    }
}

/// Subagent transcripts use the same turn rules in `.subagent` scope.
struct ClaudeSubagentTranscriptParser: JSONLMetricParser {
    private var parser: ClaudeTranscriptParser

    init(sourceIdentity: String) { parser = ClaudeTranscriptParser(sourceIdentity: sourceIdentity, scope: .subagent) }
    var hasPendingWork: Bool { parser.hasPendingWork }
    mutating func consume(line: Data) -> TurnMetric? { parser.consume(line: line) }
    mutating func pollEnded(now: Date, isFinal: Bool) -> TurnMetric? { parser.pollEnded(now: now, isFinal: isFinal) }
    mutating func drainCompletedResponses() -> [LiveResponse] { parser.drainCompletedResponses() }
    mutating func drainDelegationEvents() -> [DelegationEvent] { parser.drainDelegationEvents() }
    mutating func reset(sourceIdentity: String) { parser.reset(sourceIdentity: sourceIdentity) }
    mutating func markStartedMidFile() { parser.markStartedMidFile() }
}

/// Watches primary transcripts and `<session>/subagents/agent-*.jsonl` files under one root.
/// The two file sets use separate `JSONLSourceSessionMonitor`s, so a burst of subagent files cannot
/// consume the primary byte budget, live-file slots or 2,000-file cap (and vice versa); each set
/// keeps the full existing recent-tail/archive fairness and byte limits. The path predicates are
/// disjoint, so no transcript is counted twice.
///
/// The monitor attributes each subagent turn to the primary turn of the same session that started it
/// (see `DelegationAttributor`): a primary turn is emitted at once and re-emitted under the same id
/// once its delegated output tokens are final.
public actor ClaudeSessionMonitor {
    private let primary: JSONLSourceSessionMonitor<ClaudeTranscriptParser>
    private let subagents: JSONLSourceSessionMonitor<ClaudeSubagentTranscriptParser>
    private var attributor = DelegationAttributor()

    /// `liveSince` is the moment from which completed responses count as live; earlier responses are
    /// history and never reach the live stream.
    /// `primaryCheckpoints` and `subagentCheckpoints` are the files an earlier run read to their end,
    /// whose records are already in the history.
    public init(
        root: URL, liveSince: Date = .now,
        primaryCheckpoints: [SourceFileCheckpoint] = [], subagentCheckpoints: [SourceFileCheckpoint] = []
    ) {
        primary = JSONLSourceSessionMonitor(
            root: root, liveSince: liveSince,
            versionKey: SourceFileCheckpoint.versionKey(
                parser: ClaudeTranscriptParser.parserVersion, metric: ClaudeTranscriptParser.primaryMetricVersion
            ),
            checkpoints: primaryCheckpoints
        ) { url in
            url.pathExtension.lowercased() == "jsonl"
                && !url.lastPathComponent.hasPrefix("agent-")
                && !url.pathComponents.contains("subagents")
        }
        subagents = JSONLSourceSessionMonitor(
            root: root, liveSince: liveSince,
            versionKey: SourceFileCheckpoint.versionKey(
                parser: ClaudeTranscriptParser.parserVersion, metric: ClaudeTranscriptParser.subagentMetricVersion
            ),
            checkpoints: subagentCheckpoints
        ) { url in
            url.pathExtension.lowercased() == "jsonl" && Self.isSubagentTranscript(url)
        }
    }

    public func poll(now: Date = .now) async throws -> MonitorUpdate {
        let primaryUpdate = try await primary.poll(now: now)
        // Discovery is the only throwing step and runs before any bytes are consumed, so a failed
        // subagent poll loses nothing and is retried on the next cycle.
        let subagentPoll = try? await subagents.poll(now: now)
        let subagentUpdate = subagentPoll ?? MonitorUpdate()
        attributor.ingest(events: primaryUpdate.delegation + subagentUpdate.delegation, metrics: primaryUpdate.metrics)
        // Without a successful subagent poll nothing is known about delegated work: finalize nothing.
        let backlog = subagentPoll == nil ? DelegationBacklog.unknown : await subagents.delegationBacklog
        let finals = attributor.finalize(now: now, backlog: backlog)
        let primaryMetrics = DelegationAttributor.merging(primaryUpdate.metrics, finals: finals)
        return MonitorUpdate(
            metrics: (primaryMetrics + subagentUpdate.metrics).sorted { $0.completedAt > $1.completedAt },
            responses: (primaryUpdate.responses + subagentUpdate.responses).sorted { $0.completedAt > $1.completedAt }
        )
    }

    /// Forwards to both inner monitors; each ignores the paths its include rule rejects, so primary and
    /// subagent transcripts stay apart. Returns whether anything is now pending.
    @discardableResult
    public func noteChanges(_ change: SessionFolderChange) async -> Bool {
        let notedPrimary = await primary.noteChanges(change)
        let notedSubagents = await subagents.noteChanges(change)
        return notedPrimary || notedSubagents
    }

    /// When to poll again if nothing else changes (see `CodexSessionMonitor.nextPollDeadline`).
    public func nextPollDeadline(now: Date) async -> Date? {
        let deadlines = [
            await primary.nextPollDeadline(now: now),
            await subagents.nextPollDeadline(now: now),
            attributor.nextDeadline(now: now)
        ].compactMap { $0 }
        return deadlines.min()
    }

    /// The files of both sets read to their end, whose records are all in the history, for a later run
    /// to skip. Nil while the previous sets stay valid: before the first discovery, and while a primary
    /// turn awaits its delegated total (it is not final, and skipping its file would leave it so).
    public func checkpoints() async -> (primary: [SourceFileCheckpoint], subagents: [SourceFileCheckpoint])? {
        guard !attributor.hasPending, let primary = await primary.checkpoints(),
              let subagents = await subagents.checkpoints() else { return nil }
        return (primary, subagents)
    }

    public func status() async -> (rootAvailable: Bool, files: Int) {
        let primaryFiles = await primary.watchedFileCount, subagentFiles = await subagents.watchedFileCount
        return (await primary.rootIsAvailable, primaryFiles + subagentFiles)
    }

    private static func isSubagentTranscript(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("agent-") && url.pathComponents.contains("subagents")
    }
}
