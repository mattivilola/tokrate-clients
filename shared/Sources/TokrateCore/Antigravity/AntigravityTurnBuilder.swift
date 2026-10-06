import CryptoKit
import Foundation

/// One model call: a step whose metadata carries the usage message.
struct AntigravityModelCall: Sendable {
    let stepIndex: Int64
    let executionID: String?
    let createdAt: AntigravityInstant
    let completedAt: AntigravityInstant
    let outputTokens: Int
    let thinkingTokens: Int
    let generation: AntigravityGeneration?

    var durationSeconds: TimeInterval { completedAt.seconds(since: createdAt) }

    /// Whether the call counts as one response under the shared response rules.
    var qualifiesAsResponse: Bool {
        ResponseSpeed.qualifies(outputTokens: outputTokens, durationSeconds: durationSeconds)
    }
}

/// An execution (one agent run from the user's prompt to its final answer) that finished and reads
/// completely, with the turn it measures.
struct AntigravityFinishedExecution: Sendable {
    let executionID: String
    let metric: TurnMetric
}

/// Builds measurements from the decoded rows of one conversation database. Pure: no file access, no
/// clock, so the contract's rules ("Antigravity (0.1.18)") can be tested directly.
struct AntigravityTurnBuilder: Sendable {
    static let client = "antigravity"
    static let parserVersion = "antigravity-conversation-v1"
    static let metricVersion = "antigravity-observed-execution-v1"

    let conversationID: String
    let steps: [AntigravityStep]
    let executors: [AntigravityExecutor]
    /// Decoded generations by `gen_metadata.idx`; a missing entry is a generation that is absent or unreadable.
    let generations: [Int64: AntigravityGeneration]

    /// Every model call whose timestamps read completely and in order, whatever its execution's state.
    var modelCalls: [AntigravityModelCall] {
        steps.compactMap(modelCall)
    }

    /// The finished executions that produce a record. Each is emitted by the caller once.
    func finishedExecutions() -> [AntigravityFinishedExecution] {
        var stepsByExecution: [String: [AntigravityStep]] = [:]
        for step in steps { if let id = step.executionID { stepsByExecution[id, default: []].append(step) } }
        // An execution id with more than one executor row is ambiguous and skipped.
        let executorsByID = Dictionary(grouping: executors, by: \.executionID).compactMapValues { $0.count == 1 ? $0[0] : nil }
        return executorsByID.values.sorted { $0.executionID < $1.executionID }.compactMap { executor in
            guard executor.isFinished, let steps = stepsByExecution[executor.executionID],
                  let metric = turn(for: executor, steps: steps) else { return nil }
            return AntigravityFinishedExecution(executionID: executor.executionID, metric: metric)
        }
    }

    /// The effort of the executor that ran a call, read against the call's own model.
    func effort(of call: AntigravityModelCall) -> String? {
        guard let executionID = call.executionID else { return nil }
        let matching = executors.filter { $0.executionID == executionID }
        guard matching.count == 1, let executor = matching.first else { return nil }
        return AntigravityModelID.effort(variantID: executor.variantID, model: call.generation?.model)
    }

    // MARK: Rules

    private func modelCall(_ step: AntigravityStep) -> AntigravityModelCall? {
        guard let usage = step.usage, !step.hasUnreadableField,
              let created = step.createdAt, let completed = step.completedAt, completed >= created else { return nil }
        return AntigravityModelCall(
            stepIndex: step.idx, executionID: step.executionID, createdAt: created, completedAt: completed,
            outputTokens: usage.outputTokens, thinkingTokens: usage.thinkingTokens,
            generation: generations[step.generationIndex]
        )
    }

    private func turn(for executor: AntigravityExecutor, steps: [AntigravityStep]) -> TurnMetric? {
        let modelSteps = steps.filter(\.isModelCall)
        // Every step of the run must read completely, and every model call must have ordered timestamps.
        guard !modelSteps.isEmpty, !steps.contains(where: \.hasUnreadableField) else { return nil }
        let calls = modelSteps.compactMap(modelCall)
        guard calls.count == modelSteps.count,
              let startedAt = steps.compactMap(\.createdAt).min(),
              let completedAt = steps.compactMap({ $0.completedAt ?? $0.createdAt }).max() else { return nil }
        let duration = completedAt.seconds(since: startedAt)
        let outputTokens = calls.reduce(0) { $0 + $1.outputTokens }
        guard duration.isFinite, duration > 0,
              ResponseSpeed.isPlausibleTurnThroughput(outputTokens: outputTokens, durationSeconds: duration) else { return nil }

        // All model calls need a generation, and they must agree, for the turn to have a model.
        let names = calls.map { $0.generation?.model }
        let model: String? = names.first.flatMap { $0 }.flatMap { first in names.allSatisfy { $0 == first } ? first : nil }
        let provider = model != nil && calls.allSatisfy({ $0.generation?.provider == "google" }) ? "google" : "unknown"

        let responses = calls.filter(\.qualifiesAsResponse)
        let responseTokens = responses.reduce(0) { $0 + $1.outputTokens }
        let responseSeconds = responses.reduce(0) { $0 + $1.durationSeconds }
        let digest = SHA256.hash(data: Data("antigravity|\(conversationID)|\(executor.executionID)".utf8))
        let metric = TurnMetric(
            id: digest.map { String(format: "%02x", $0) }.joined(),
            completedAt: completedAt.date,
            model: model,
            outputTokens: outputTokens,
            durationSeconds: duration,
            codexTTFTSeconds: nil,
            turnThroughputTPS: Double(outputTokens) / duration,
            streamingTPS: nil,
            client: Self.client,
            clientVersion: nil,
            parserVersion: Self.parserVersion,
            metricVersion: Self.metricVersion,
            reasoningOutputTokens: calls.reduce(0) { $0 + $1.thinkingTokens },
            sourceKind: "primary",
            provider: provider,
            reasoningEffort: AntigravityModelID.effort(variantID: executor.variantID, model: model),
            responseOutputTokens: responses.isEmpty ? nil : responseTokens,
            responseDurationSeconds: responses.isEmpty ? nil : responseSeconds,
            responseCount: responses.isEmpty ? nil : responses.count,
            // Subagent work started by this run is not part of its tokens and cannot be attributed yet:
            // the turn stays pending (shown locally, never shared) instead of claiming zero.
            delegatedOutputTokens: steps.contains(where: \.hasSubtrajectory) ? nil : 0
        )
        let hasResponse = metric.responseOutputTokens != nil
        return hasResponse && !metric.hasPlausibleResponseTiming ? metric.withoutResponseTiming() : metric
    }
}
