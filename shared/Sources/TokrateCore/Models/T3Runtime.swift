import Foundation

/// T3 is the tool; the existing parser/metric pair remains the measurement definition.
public enum T3Runtime {
    public static let client = "t3-code"

    public static func nativeClient(parser: String, metric: String) -> String? {
        switch (parser, metric) {
        case ("codex-rollout-v2", "turn-v1"): "codex"
        case ("claude-transcript-v4", "claude-observed-turn-v1"),
             ("claude-transcript-v4", "claude-observed-subagent-turn-v1"): "claude-code"
        case ("antigravity-conversation-v1", "antigravity-observed-execution-v1"): "antigravity"
        default: nil
        }
    }

    public static func isCodexOriginator(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return ["t3 code", "t3code_desktop"].contains(value)
    }

    static func outcomeRuntime(client: String, parser: String) -> String? {
        guard client == Self.client else { return client }
        switch parser {
        case "codex-rollout-v2": return "codex"
        case "claude-transcript-v4": return "claude-code"
        default: return nil
        }
    }
}
