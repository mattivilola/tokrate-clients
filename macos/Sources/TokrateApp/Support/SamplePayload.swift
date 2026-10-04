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
            reasoningEffort: "medium"
        )
    }

    /// Pretty-printed JSON of one example upload, with sorted keys.
    static func exampleJSON() -> String {
        guard let sample = SharedSample(exampleMetric(), sampleId: UUID(uuidString: "00000000-0000-4000-8000-000000000000")!),
              let data = try? SampleEnvelope(sentAt: Date(timeIntervalSince1970: 1_767_269_100), samples: [sample]).encoded(),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: pretty, encoding: .utf8) else {
            return "{ }"
        }
        return text
    }
}
