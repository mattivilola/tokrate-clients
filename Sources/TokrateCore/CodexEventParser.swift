import CoreFoundation
import CryptoKit
import Foundation

/// Reads the observed Codex JSONL event shape and emits completed-turn metrics only.
/// Message bodies, prompts, account metadata, and session identifiers are never returned.
public struct CodexEventParser: Sendable {
    private struct TurnState: Sendable {
        var startedAt: Date?
        var outputTokens: Int?
        var reasoningOutputTokens: Int?
        var durationMilliseconds: Double?
        var ttftMilliseconds: Double?
        var model: String?
        var modelWasAmbiguous = false
    }

    private var sourceIdentity: String
    private var sessionIdentity: String?
    private var turns: [String: TurnState] = [:]
    private var emittedTurnIDs: Set<String> = []
    private var isAgentSession = false
    private var clientVersion: String?
    private var sourceKind = "unknown"
    private var provider = "unknown"

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
        clientVersion = nil
        sourceKind = "unknown"
        provider = "unknown"
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
            provider = payload["model_provider"] as? String == "openai" ? "openai" : "unknown"
            if let source = payload["source"] as? String, ["cli", "vscode", "exec", "desktop", "app"].contains(source) { sourceKind = "primary" }
            if let source = payload["source"] as? [String: Any], source["subagent"] != nil { isAgentSession = true }
            if let id = payload["id"] as? String, !id.isEmpty { sessionIdentity = id }
            if let parent = payload["parent_thread_id"] as? String, !parent.isEmpty { isAgentSession = true }
            if let path = payload["agent_path"] as? String, !path.isEmpty { isAgentSession = true }
            if let path = payload["agent_path"] as? [Any], !path.isEmpty { isAgentSession = true }
            return nil
        }

        if turns.count > 4096 { turns.removeAll(keepingCapacity: true) }
        if emittedTurnIDs.count > 8192 { emittedTurnIDs.removeAll(keepingCapacity: true) }
        let eventDate = parseDate(event["timestamp"])

        if eventType == "turn_context" {
            guard let turnID = payload["turn_id"] as? String, !turnID.isEmpty else { return nil }
            var state = turns[turnID, default: TurnState()]
            updateModel(payload["model"] as? String, in: &state)
            turns[turnID] = state
            return nil
        }

        if eventType == "token_usage_record" {
            guard let turnID = payload["turn_id"] as? String, !turnID.isEmpty else { return nil }
            var state = turns[turnID, default: TurnState()]
            if let usage = payload["turn_token_usage"] as? [String: Any],
               let output = nonnegativeInteger(usage["output_tokens"]) {
                // Codex reports cumulative per-turn usage. A later record replaces the prior total.
                state.outputTokens = output
                state.reasoningOutputTokens = nonnegativeInteger(usage["reasoning_output_tokens"])
            }
            turns[turnID] = state
            return nil
        }

        guard eventType == "event_msg",
              let subtype = payload["type"] as? String,
              let turnID = payload["turn_id"] as? String,
              !turnID.isEmpty
        else { return nil }

        if subtype == "task_started" {
            var state = turns[turnID, default: TurnState()]
            if state.startedAt == nil { state.startedAt = parseDate(payload["started_at"]) ?? eventDate }
            turns[turnID] = state
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
        let duration = state.durationMilliseconds.map { $0 / 1_000 }
            ?? state.startedAt.flatMap { start in completedAt.map { $0.timeIntervalSince(start) } }
        guard !isAgentSession,
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
        guard throughput.isFinite, throughput >= 0 else {
            turns[turnID] = state
            return nil
        }

        emittedTurnIDs.insert(turnID)
        turns.removeValue(forKey: turnID)
        let identity = sessionIdentity ?? sourceIdentity
        let digest = SHA256.hash(data: Data("\(identity)|\(turnID)".utf8))
        return TurnMetric(
            id: digest.map { String(format: "%02x", $0) }.joined(),
            completedAt: completedAt,
            model: state.modelWasAmbiguous ? nil : state.model,
            outputTokens: outputTokens,
            durationSeconds: duration,
            codexTTFTSeconds: ttft,
            turnThroughputTPS: throughput,
            streamingTPS: nil,
            clientVersion: clientVersion,
            reasoningOutputTokens: state.reasoningOutputTokens,
            sourceKind: sourceKind,
            provider: provider
        )
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
