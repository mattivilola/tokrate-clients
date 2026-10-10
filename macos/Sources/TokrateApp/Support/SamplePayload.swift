import Foundation
import TokrateCore

/// The "See exactly what is sent" example. It runs obviously fake values through the real upload
/// allowlist and encoder, so the field names can never drift from what is actually uploaded.
enum SamplePayload {
    /// Fixed fake values: nothing here comes from the user's history.
    static func exampleMetric() -> TurnMetric {
        TurnMetric(
            id: "example-local-id-never-uploaded",
            completedAt: Date(timeIntervalSince1970: 1_767_268_980),
            model: "example-model",
            outputTokens: 1_234,
            durationSeconds: 20,
            codexTTFTSeconds: 0.84,
            turnThroughputTPS: 61.7,
            client: "codex",
            clientVersion: "1.2.3",
            reasoningOutputTokens: 400,
            sourceKind: "primary",
            provider: "openai",
            reasoningEffort: "medium",
            responseOutputTokens: 1_000,
            responseDurationSeconds: 12.5,
            responseCount: 3,
            delegatedOutputTokens: 0,
            surface: .cli,
            inputTokens: 48_000,
            cacheReadInputTokens: 36_000
        )
    }

    /// Fixed fake request counts for the same five-minute period: nothing here comes from the user's logs.
    static func exampleRequestCount() -> SharedRequestCount? {
        SharedRequestCount(
            countId: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            observedAt: Date(timeIntervalSince1970: 1_767_268_800), client: "claude-code", clientVersion: "1.2.3",
            parserVersion: "claude-transcript-v4", model: "example-model", provider: "anthropic",
            succeeded: 41, overloaded: 3, serverError: 0
        )
    }

    /// Pretty-printed JSON of one example upload, with sorted keys.
    static func exampleJSON() -> String {
        guard let sample = SharedSample(exampleMetric(), sampleId: UUID(uuidString: "00000000-0000-4000-8000-000000000000")!),
              let count = exampleRequestCount(),
              let data = try? SampleEnvelope(sentAt: Date(timeIntervalSince1970: 1_767_269_100), samples: [sample], requestCounts: [count]).encoded(),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: pretty, encoding: .utf8) else {
            return "{ }"
        }
        return text
    }
}
