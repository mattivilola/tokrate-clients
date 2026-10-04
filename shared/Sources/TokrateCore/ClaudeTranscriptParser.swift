import CoreFoundation
import CryptoKit
import Foundation

/// Parses only complete primary Claude Code user turns. Transcript text is inspected only to
/// reject tool-result records and is never retained in a metric or shared sample.
struct ClaudeTranscriptParser: JSONLMetricParser {
    private struct MessageUsage: Sendable {
        var outputTokens: Int?
    }

    private struct TurnState: Sendable {
        let startedAt: Date
        let userTurnID: String
        let sessionID: String?
        var messages: [String: MessageUsage] = [:]
        var hasIncompleteUsage = false
        var hasModellessMessage = false
        var model: String?
        var modelIsAmbiguous = false
        var clientVersion: String?
        var versionIsAmbiguous = false
        var reasoningEffort: String?
        var effortIsAmbiguous = false
    }

    private var sourceIdentity: String
    private var turn: TurnState?
    private var emittedUserTurnIDs: Set<String> = []

    init(sourceIdentity: String) { self.sourceIdentity = sourceIdentity }

    mutating func reset(sourceIdentity: String) {
        self.sourceIdentity = sourceIdentity
        turn = nil
        emittedUserTurnIDs.removeAll(keepingCapacity: true)
    }

    mutating func consume(line: Data) -> TurnMetric? {
        guard line.count <= JSONLFileReader.maximumLineBytes,
              let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = root["type"] as? String
        else { return nil }

        if emittedUserTurnIDs.count > 8_192 { emittedUserTurnIDs.removeAll(keepingCapacity: true) }
        if type == "user" {
            guard isPrimaryHumanRecord(root), let userID = safeIdentifier(root["uuid"] as? String, maximum: 120),
                  !emittedUserTurnIDs.contains(userID), let startedAt = parseDate(root["timestamp"]),
                  let content = (root["message"] as? [String: Any])?["content"], !containsToolResult(content)
            else { return nil }
            let sessionID = safeIdentifier(root["sessionId"] as? String, maximum: 120)
            var state = TurnState(startedAt: startedAt, userTurnID: userID, sessionID: sessionID)
            if let version = validatedVersion(root["version"]) { state.clientVersion = version }
            updateEffort(root, message: nil, in: &state)
            turn = state
            return nil
        }

        guard type == "assistant", var state = turn,
              isPrimaryHumanRecord(root),
              let message = root["message"] as? [String: Any]
        else { return nil }

        if let sessionID = safeIdentifier(root["sessionId"] as? String, maximum: 120),
           let original = state.sessionID, sessionID != original {
            state.hasIncompleteUsage = true
        }
        if let version = validatedVersion(root["version"]) {
            if let old = state.clientVersion, old != version { state.versionIsAmbiguous = true }
            else if state.clientVersion == nil { state.clientVersion = version }
        }
        updateEffort(root, message: message, in: &state)

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
        if let model = safeIdentifier(message["model"] as? String, maximum: 80) {
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
        let stopReason = message["stop_reason"] as? String
        guard stopReason == "end_turn" || stopReason == "stop_sequence" else {
            turn = state
            return nil
        }

        turn = nil
        guard !state.hasIncompleteUsage,
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
        let identity = state.sessionID ?? sourceIdentity
        let digest = SHA256.hash(data: Data("\(identity)|\(state.userTurnID)".utf8))
        return TurnMetric(
            id: digest.map { String(format: "%02x", $0) }.joined(),
            completedAt: completedAt,
            model: state.modelIsAmbiguous || state.hasModellessMessage ? nil : state.model,
            outputTokens: total,
            durationSeconds: duration,
            codexTTFTSeconds: nil,
            turnThroughputTPS: throughput,
            streamingTPS: nil,
            client: "claude-code",
            clientVersion: state.versionIsAmbiguous ? nil : state.clientVersion,
            parserVersion: "claude-transcript-v1",
            metricVersion: "claude-observed-turn-v1",
            sourceKind: "primary",
            provider: "unknown",
            reasoningEffort: state.effortIsAmbiguous ? nil : state.reasoningEffort
        )
    }

    private func isPrimaryHumanRecord(_ event: [String: Any]) -> Bool {
        event["isSidechain"] as? Bool == false
            && event["userType"] as? String == "external"
            && event["agentId"] == nil
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

public actor ClaudeSessionMonitor {
    private let monitor: JSONLSourceSessionMonitor<ClaudeTranscriptParser>

    public init(root: URL) {
        monitor = JSONLSourceSessionMonitor(root: root) { url in
            url.pathExtension.lowercased() == "jsonl"
                && !url.lastPathComponent.hasPrefix("agent-")
                && !url.pathComponents.contains("subagents")
        }
    }

    public func poll(now: Date = .now) async throws -> [TurnMetric] {
        try await monitor.poll(now: now)
    }

    public func status() async -> (rootAvailable: Bool, files: Int) {
        (await monitor.rootIsAvailable, await monitor.watchedFileCount)
    }
}
