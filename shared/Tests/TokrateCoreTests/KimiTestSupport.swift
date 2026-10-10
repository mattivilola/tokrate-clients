import Foundation
@testable import TokrateCore

/// Builders for synthetic Kimi Code `wire.jsonl` records. Times are seconds from `origin`, written as
/// the whole milliseconds the real logs carry.
enum KimiLog {
    static let origin = 1_791_543_000_000
    static let mainPath = "/tmp/kimi/sessions/wd_x/conv-1/agents/main/wire.jsonl"
    static let subagentPath = "/tmp/kimi/sessions/wd_x/conv-1/agents/sub-1/wire.jsonl"

    static func milliseconds(_ seconds: Double) -> Int { origin + Int((seconds * 1_000).rounded()) }

    static func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: Double(milliseconds(seconds)) / 1_000) }

    static func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// A `turn.prompt`; a nil origin leaves the field out, as older logs do.
    static func prompt(at seconds: Double, origin: [String: Any]? = ["kind": "user"]) -> Data {
        var record: [String: Any] = ["type": "turn.prompt", "time": milliseconds(seconds)]
        record["origin"] = origin
        return line(record)
    }

    static func begin(_ turn: String, _ step: Int, at seconds: Double) -> Data {
        loopEvent(["type": "step.begin", "turnId": turn, "step": step], at: seconds)
    }

    static func request(
        _ turn: String, _ step: Int, at seconds: Double,
        model: String? = "k2d8-preview", provider: String? = "kimi", effort: String? = "high"
    ) -> Data {
        var record: [String: Any] = ["type": "llm.request", "time": milliseconds(seconds), "kind": "loop", "turnStep": "\(turn).\(step)"]
        record["model"] = model
        record["provider"] = provider
        record["thinkingEffort"] = effort
        return line(record)
    }

    static func usage(output: Int = 300, inputOther: Int = 100, cacheRead: Int = 900, cacheCreation: Int = 0) -> [String: Any] {
        ["inputOther": inputOther, "output": output, "inputCacheRead": cacheRead, "inputCacheCreation": cacheCreation]
    }

    static func end(
        _ turn: String, _ step: Int, at seconds: Double, finish: String? = "tool_use", usage: [String: Any]? = KimiLog.usage()
    ) -> Data {
        var event: [String: Any] = ["type": "step.end", "turnId": turn, "step": step]
        event["finishReason"] = finish
        event["usage"] = usage
        return loopEvent(event, at: seconds)
    }

    /// One complete model call: `step.begin`, its request one millisecond later, and `step.end`.
    static func step(
        _ turn: String, _ step: Int, begin: Double, end: Double, finish: String? = "tool_use", output: Int = 300,
        model: String? = "k2d8-preview", provider: String? = "kimi", effort: String? = "high",
        usage: [String: Any]? = nil
    ) -> [Data] {
        [
            Self.begin(turn, step, at: begin),
            request(turn, step, at: begin + 0.001, model: model, provider: provider, effort: effort),
            Self.end(turn, step, at: end, finish: finish, usage: usage ?? Self.usage(output: output))
        ]
    }

    static func turnEnded(_ turnID: Any, reason: String, at seconds: Double) -> Data {
        line(["type": "turn.ended", "time": milliseconds(seconds), "turnId": turnID, "reason": reason])
    }

    /// A `turn.ended` that carries an error; the message is private text that must never be read.
    static func turnFailed(
        _ turnID: Any, code: String, status: Int? = nil, name: String = "APIStatusError", at seconds: Double
    ) -> Data {
        var details: [String: Any] = ["requestId": NSNull(), "traceId": "trace"]
        details["statusCode"] = status
        return line([
            "type": "turn.ended", "time": milliseconds(seconds), "turnId": turnID, "reason": "failed", "durationMs": 1_000,
            "error": ["code": code, "name": name, "message": "PRIVATE_ERROR_TEXT", "details": details, "retryable": false]
        ])
    }

    static func stepRetrying(_ turnID: String, at seconds: Double, status: Int = 529) -> Data {
        line([
            "type": "turn.step.retrying", "time": milliseconds(seconds), "turnId": turnID, "step": 1, "failedAttempt": 1,
            "nextAttempt": 2, "maxAttempts": 3, "delayMs": 500, "errorName": "APIProviderOverloadedError",
            "errorMessage": "PRIVATE_ERROR_TEXT", "statusCode": status
        ])
    }

    static func promptCompleted(at seconds: Double) -> Data {
        line(["type": "prompt.completed", "time": milliseconds(seconds), "promptId": "p1", "reason": "failed"])
    }

    static func agentTurnEnded(_ turnID: Any, outcome: String, at seconds: Double) -> Data {
        line(["type": "agent.turn.ended", "time": milliseconds(seconds), "turnId": turnID, "outcome": outcome])
    }

    static func stepInterrupted(_ turnID: Any, at seconds: Double) -> Data {
        line(["type": "turn.step.interrupted", "time": milliseconds(seconds), "turnId": turnID, "step": 1, "reason": "error"])
    }

    static func promptAborted(at seconds: Double) -> Data {
        line(["type": "prompt.aborted", "time": milliseconds(seconds)])
    }

    private static func loopEvent(_ event: [String: Any], at seconds: Double) -> Data {
        line(["type": "context.append_loop_event", "time": milliseconds(seconds), "event": event])
    }

    /// The sanitized copy of a real Kimi log the Rust client's tests share.
    static func fixture(_ name: String) throws -> [Data] {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { directory.deleteLastPathComponent() }
        let url = directory.appendingPathComponent("desktop/core/tests/fixtures/kimi/\(name).jsonl")
        return try Data(contentsOf: url).split(separator: 0x0A).map { Data($0) }
    }

    static func jsonl(_ lines: [Data]) -> Data {
        lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
    }
}

/// What one parser produced from a list of lines.
struct KimiParse {
    var metrics: [TurnMetric] = []
    var responses: [LiveResponse] = []
    var events: [DelegationEvent] = []
    var outcomes: [RequestOutcome] = []
}

extension KimiWireParser {
    /// Feeds `lines` to a fresh parser.
    static func parse(
        _ lines: [Data], scope: Scope = .main, surface: ToolSurface = .cli, path: String = KimiLog.mainPath,
        startedMidFile: Bool = false
    ) -> KimiParse {
        var parser = KimiWireParser(sourceIdentity: path, scope: scope, surface: surface)
        if startedMidFile { parser.markStartedMidFile() }
        var result = KimiParse()
        for line in lines { if let metric = parser.consume(line: line) { result.metrics.append(metric) } }
        result.responses = parser.drainCompletedResponses()
        result.events = parser.drainDelegationEvents()
        result.outcomes = parser.drainRequestOutcomes()
        return result
    }
}
