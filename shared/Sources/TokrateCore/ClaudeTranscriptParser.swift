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

    static let parserVersion = "claude-transcript-v3"
    static let primaryMetricVersion = "claude-observed-turn-v1"
    static let subagentMetricVersion = "claude-observed-subagent-turn-v1"
    static let maximumInterjectionGap: TimeInterval = 30 * 60
    private static let syntheticModel = "<synthetic>"
    private static let interruptionPrefix = "[Request interrupted by user"

    private struct MessageUsage: Sendable {
        var outputTokens: Int?
    }

    private struct TurnState: Sendable {
        let startedAt: Date
        let userTurnID: String
        let sessionID: String?
        let agentID: String?
        var lastActivityAt: Date
        var messages: [String: MessageUsage] = [:]
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
        var reasoningEffort: String?
        var effortIsAmbiguous = false
    }

    private let scope: Scope
    private var sourceIdentity: String
    private var turn: TurnState?
    private var emittedUserTurnIDs: Set<String> = []
    /// False while a reader that started mid-file has not yet reached a reliable turn boundary.
    private var isSynchronised = true

    init(sourceIdentity: String) { self.init(sourceIdentity: sourceIdentity, scope: .primary) }

    init(sourceIdentity: String, scope: Scope) {
        self.sourceIdentity = sourceIdentity
        self.scope = scope
    }

    mutating func reset(sourceIdentity: String) {
        self.sourceIdentity = sourceIdentity
        turn = nil
        isSynchronised = true
        emittedUserTurnIDs.removeAll(keepingCapacity: true)
    }

    /// A reader that starts mid-file can see the end of a turn whose start it never saw. Until the
    /// first terminal assistant record or a conversation-root prompt (`parentUuid` null), prompts
    /// are ignored so no partial turn is measured.
    mutating func markStartedMidFile() {
        turn = nil
        isSynchronised = false
    }

    mutating func consume(line: Data) -> TurnMetric? {
        guard line.count <= JSONLFileReader.maximumLineBytes,
              let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = root["type"] as? String,
              isAcceptedRecord(root)
        else { return nil }

        if emittedUserTurnIDs.count > 8_192 { emittedUserTurnIDs.removeAll(keepingCapacity: true) }
        switch type {
        case "user":
            consumeUser(root)
            return nil
        case "assistant":
            return consumeAssistant(root)
        default:
            return nil
        }
    }

    private mutating func consumeUser(_ root: [String: Any]) {
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
            turn = nil
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
        turn = nil
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
        updateEffort(root, message: nil, in: &state)
        turn = state
    }

    private mutating func consumeAssistant(_ root: [String: Any]) -> TurnMetric? {
        if !isSynchronised {
            let stopReason = (root["message"] as? [String: Any])?["stop_reason"] as? String
            if stopReason == "end_turn" || stopReason == "stop_sequence" { isSynchronised = true }
        }
        guard var state = turn, let message = root["message"] as? [String: Any] else { return nil }

        if let timestamp = parseDate(root["timestamp"]) { state.lastActivityAt = max(state.lastActivityAt, timestamp) }
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
        updateEffort(root, message: message, in: &state)

        if message["model"] as? String == Self.syntheticModel {
            state.hasSyntheticMessage = true
        } else {
            guard let messageID = safeIdentifier(message["id"] as? String, maximum: 120) else {
                state.hasIncompleteUsage = true
                turn = state
                return nil
            }
            if state.messages[messageID] == nil && state.messages.count >= 4_096 {
                state.hasIncompleteUsage = true
                turn = state
                return nil
            }
            if let provider = ClaudeProviderEvidence.provider(
                messageID: message["id"] as? String, requestID: root["requestId"] as? String
            ) {
                state.providers.insert(provider)
            } else {
                state.hasRecordWithoutProviderEvidence = true
            }
            if let model = safeIdentifier(ClaudeModelID.normalized(message["model"] as? String), maximum: 80) {
                if let existing = state.model, existing != model { state.modelIsAmbiguous = true }
                else if state.model == nil { state.model = model }
            } else {
                state.hasModellessMessage = true
            }

            let output = nonnegativeInteger((message["usage"] as? [String: Any])?["output_tokens"])
            if var existing = state.messages[messageID] {
                if let prior = existing.outputTokens, let output, output < prior { state.hasIncompleteUsage = true }
                if let output, existing.outputTokens.map({ output >= $0 }) ?? true {
                    existing.outputTokens = output
                }
                state.messages[messageID] = existing
            } else {
                state.messages[messageID] = MessageUsage(outputTokens: output)
            }
        }
        let stopReason = message["stop_reason"] as? String
        guard stopReason == "end_turn" || stopReason == "stop_sequence" else {
            turn = state
            return nil
        }

        turn = nil
        guard !state.hasSyntheticMessage,
              !state.hasIncompleteUsage,
              !state.messages.isEmpty,
              state.messages.values.allSatisfy({ $0.outputTokens != nil }),
              let completedAt = parseDate(root["timestamp"]),
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
        let throughput = Double(total) / duration
        guard throughput.isFinite, throughput >= 0 else { return nil }
        emittedUserTurnIDs.insert(state.userTurnID)
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
            provider: state.hasRecordWithoutProviderEvidence || state.providers.count != 1
                ? "unknown" : state.providers.first ?? "unknown",
            reasoningEffort: state.effortIsAmbiguous ? nil : state.reasoningEffort
        )
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
    mutating func consume(line: Data) -> TurnMetric? { parser.consume(line: line) }
    mutating func reset(sourceIdentity: String) { parser.reset(sourceIdentity: sourceIdentity) }
    mutating func markStartedMidFile() { parser.markStartedMidFile() }
}

/// Watches primary transcripts and `<session>/subagents/agent-*.jsonl` files under one root.
/// The two file sets use separate `JSONLSourceSessionMonitor`s, so a burst of subagent files cannot
/// consume the primary byte budget, live-file slots or 2,000-file cap (and vice versa); each set
/// keeps the full existing recent-tail/archive fairness and byte limits. The path predicates are
/// disjoint, so no transcript is counted twice.
public actor ClaudeSessionMonitor {
    private let primary: JSONLSourceSessionMonitor<ClaudeTranscriptParser>
    private let subagents: JSONLSourceSessionMonitor<ClaudeSubagentTranscriptParser>

    public init(root: URL) {
        primary = JSONLSourceSessionMonitor(root: root) { url in
            url.pathExtension.lowercased() == "jsonl"
                && !url.lastPathComponent.hasPrefix("agent-")
                && !url.pathComponents.contains("subagents")
        }
        subagents = JSONLSourceSessionMonitor(root: root) { url in
            url.pathExtension.lowercased() == "jsonl" && Self.isSubagentTranscript(url)
        }
    }

    public func poll(now: Date = .now) async throws -> [TurnMetric] {
        let primaryRecords = try await primary.poll(now: now)
        // Discovery is the only throwing step and runs before any bytes are consumed, so a failed
        // subagent poll loses nothing and is retried on the next cycle.
        let subagentRecords = (try? await subagents.poll(now: now)) ?? []
        return (primaryRecords + subagentRecords).sorted { $0.completedAt > $1.completedAt }
    }

    public func status() async -> (rootAvailable: Bool, files: Int) {
        let primaryFiles = await primary.watchedFileCount, subagentFiles = await subagents.watchedFileCount
        return (await primary.rootIsAvailable, primaryFiles + subagentFiles)
    }

    private static func isSubagentTranscript(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("agent-") && url.pathComponents.contains("subagents")
    }
}
