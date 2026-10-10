import Foundation
import XCTest
@testable import TokrateCore

private let privateText = "PRIVATE_ERROR_TEXT"

private func counts(_ outcomes: [RequestOutcome]) -> [RequestOutcome.Kind: Int] {
    Dictionary(outcomes.map { ($0.kind, 1) }, uniquingKeysWith: +)
}

/// Request outcomes of Claude Code transcripts (contract "Request outcomes (0.1.22)", per-tool mapping).
final class ClaudeRequestOutcomeTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let session = "synthetic-session"
    private let agent = "a0123456789abcdef"

    // MARK: Fixtures

    private func stamp(_ seconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: base.addingTimeInterval(seconds))
    }

    private func envelope(sidechain: Bool) -> [String: Any] {
        var value: [String: Any] = ["sessionId": session, "isSidechain": sidechain, "userType": "external", "version": "2.1.295"]
        if sidechain { value["agentId"] = agent }
        return value
    }

    private func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func messageID(_ number: Int, prefix: String = "msg_01") -> String { prefix + String(format: "%022d", number) }

    /// A real response record with usage. The first-party provider needs a `msg_01…` id and a `req_…` id.
    private func real(
        at seconds: Double, number: Int, model: String = "claude-opus-5-5", output: Int = 40, stop: String? = "end_turn",
        prefix: String = "msg_01", requestID: String? = "req_011CABCDEFGHIJKLMNOPQRST", sidechain: Bool = false
    ) throws -> Data {
        var value = envelope(sidechain: sidechain)
        value["type"] = "assistant"
        value["uuid"] = "record-\(number)-\(Int(seconds))"
        value["timestamp"] = stamp(seconds)
        if let requestID { value["requestId"] = requestID }
        value["message"] = [
            "id": messageID(number, prefix: prefix), "role": "assistant", "model": model,
            "content": [["type": "text", "text": "PRIVATE_RESPONSE"]], "stop_reason": stop ?? NSNull(),
            "usage": ["output_tokens": output, "input_tokens": 1]
        ] as [String: Any]
        return try json(value)
    }

    private func userRecord(at seconds: Double, id: String = "prompt", sidechain: Bool = false) throws -> Data {
        var value = envelope(sidechain: sidechain)
        value["type"] = "user"
        value["uuid"] = id
        value["parentUuid"] = NSNull()
        value["timestamp"] = stamp(seconds)
        value["message"] = ["role": "user", "content": "PRIVATE_PROMPT"]
        return try json(value)
    }

    /// The synthetic record Claude Code writes when a request fails for good.
    private func failure(
        at seconds: Double, uuid: String, status: Int?, error: String? = "server_error", text: String,
        sidechain: Bool = false, marker: Bool = true, extra: [String: Any] = [:]
    ) throws -> Data {
        var value = envelope(sidechain: sidechain)
        value["type"] = "assistant"
        value["uuid"] = uuid
        value["timestamp"] = stamp(seconds)
        if marker { value["isApiErrorMessage"] = true }
        if let error { value["error"] = error }
        if let status { value["apiErrorStatus"] = status }
        value["message"] = [
            "id": "0f0d7a52-3c52-4d4a-9c43-000000000000", "role": "assistant", "model": "<synthetic>",
            "stop_reason": "stop_sequence", "usage": ["input_tokens": 0, "output_tokens": 0],
            "content": [["type": "text", "text": text]]
        ] as [String: Any]
        value.merge(extra) { _, new in new }
        return try json(value)
    }

    private func outcomes(
        _ lines: [Data], scope: ClaudeTranscriptParser.Scope = .primary, identity: String = "/tmp/claude/synthetic.jsonl"
    ) -> [RequestOutcome] {
        var parser = ClaudeTranscriptParser(sourceIdentity: identity, scope: scope)
        for line in lines { _ = parser.consume(line: line) }
        _ = parser.pollEnded(now: base, isFinal: true)
        return parser.drainRequestOutcomes()
    }

    private func kinds(after failureLine: Data) throws -> [RequestOutcome.Kind] {
        let lines = [try real(at: 1, number: 1), failureLine]
        return outcomes(lines).filter { $0.kind != .succeeded }.map(\.kind)
    }

    // MARK: Failures

    func testStatus529IsOverloadedAndTakesTheModelAndProviderOfTheLatestRealResponse() throws {
        let result = outcomes([
            try userRecord(at: 0),
            try real(at: 1, number: 1, model: "claude-sonnet-5-5", stop: "tool_use"),
            try real(at: 3, number: 2, model: "claude-opus-5-5"),
            try failure(at: 10, uuid: "failure-1", status: 529, text: "API Error: Repeated 529 Overloaded errors. \(privateText)")
        ])
        let failed = try XCTUnwrap(result.last)
        XCTAssertEqual(failed.kind, .overloaded)
        XCTAssertEqual(failed.model, "claude-opus-5-5", "the most recent real response, not an earlier one")
        XCTAssertEqual(failed.provider, "anthropic")
        XCTAssertEqual(failed.client, "claude-code")
        XCTAssertEqual(failed.parserVersion, "claude-transcript-v4")
        XCTAssertEqual(failed.clientVersion, "2.1.295")
        XCTAssertEqual(failed.occurredAt, base.addingTimeInterval(10))
        XCTAssertEqual(counts(result), [.succeeded: 2, .overloaded: 1])
    }

    func testEveryProviderSideSignalIsClassified() throws {
        let cases: [(status: Int?, error: String?, text: String, kind: RequestOutcome.Kind?)] = [
            (500, "server_error", "API Error: 500 Internal server error", .serverError),
            (503, "server_error", "API Error: 503", .serverError),
            (599, "server_error", "x", .serverError),
            (529, "server_error", "x", .overloaded),
            (nil, "server_error", "API Error: Repeated 529 Overloaded errors. The API is at capacity", .overloaded),
            (429, "rate_limit", "Opus is experiencing high load, please use /model to switch to Sonnet", .overloaded),
            (nil, "rate_limit", "Fable is experiencing high load, please use /model", .overloaded),
            (429, "rate_limit", "API Error: Server is temporarily limiting requests (not your usage limit)", .overloaded),
            (nil, "server_error", "API Error: Server error mid-response. The response above may be incomplete.", .serverError),
            // The user's own limits and everything else the provider is not at fault for.
            (429, "rate_limit", "You've hit your session limit · resets 9:30pm (Europe/Paris)", nil),
            (429, "rate_limit", "API Error: Request rejected (429) . rate limited", nil),
            (401, "authentication_failed", "Invalid API key · Please run /login", nil),
            (403, "authentication_failed", "Your account is on hold", nil),
            (402, "billing_error", "Credit balance is too low", nil),
            (400, "invalid_request", "Prompt is too long", nil),
            (413, "invalid_request", "request_too_large", nil),
            (404, "model_not_found", "model not found", nil),
            (nil, "server_error", "API Error: Connection to the API was lost (ECONNRESET). This is usually temporary", nil),
            (nil, "server_error", "Request timed out", nil),
            (nil, "server_error", "API Error: No response from API", nil),
            (nil, "server_error", "API Error: Connection lost mid-response. The response above may be incomplete.", nil),
            (nil, "unknown", "something", nil),
            (nil, nil, "Invalid API key · Please run /login", nil)
        ]
        for entry in cases {
            let result = try kinds(after: failure(at: 5, uuid: "failure", status: entry.status, error: entry.error, text: entry.text))
            XCTAssertEqual(result, entry.kind.map { [$0] } ?? [], "\(entry.status.map(String.init) ?? "-") \(entry.text)")
        }
    }

    func testOnlyARecordMarkedAsAnApiErrorIsAFailure() throws {
        XCTAssertEqual(try kinds(after: failure(at: 5, uuid: "f", status: 529, text: "x", marker: false)), [])
    }

    func testAFirstRequestThatFailsHasNoModelAndIsDropped() throws {
        let result = outcomes([try userRecord(at: 0), try failure(at: 2, uuid: "f", status: 529, text: "x")])
        XCTAssertTrue(result.isEmpty)
        let afterwards = outcomes([try failure(at: 2, uuid: "f", status: 529, text: "x"), try real(at: 3, number: 1)])
        XCTAssertEqual(counts(afterwards), [.succeeded: 1], "a later response does not give the earlier failure a model")
    }

    func testAFailureOnAnUnknownRouteIsDropped() throws {
        // No `req_…` id: the provider is not established, so neither is the failure's.
        let result = outcomes([
            try real(at: 1, number: 1, requestID: nil),
            try failure(at: 2, uuid: "f", status: 529, text: "x")
        ])
        XCTAssertTrue(result.isEmpty, "a response without provider evidence is no outcome, and neither is its failure")
    }

    func testBedrockAndVertexFailuresKeepTheirProvider() throws {
        let bedrock = outcomes([
            try real(at: 1, number: 1, model: "us.anthropic.claude-sonnet-4-5-20250929-v1:0", prefix: "msg_bdrk_", requestID: nil),
            try failure(at: 2, uuid: "f", status: 500, text: "x")
        ])
        XCTAssertEqual(bedrock.map(\.provider), ["amazon-bedrock", "amazon-bedrock"])
        XCTAssertEqual(bedrock.map(\.model), ["claude-sonnet-4-5-20250929", "claude-sonnet-4-5-20250929"])
        let vertex = outcomes([
            try real(at: 1, number: 1, model: "claude-sonnet-4-5@20250929", prefix: "msg_vrtx_", requestID: nil),
            try failure(at: 2, uuid: "f", status: 500, text: "x")
        ])
        XCTAssertEqual(vertex.map(\.provider), ["google-vertex", "google-vertex"])
    }

    func testRetryRecordsAreNeverCounted() throws {
        var retry = envelope(sidechain: false)
        retry["type"] = "system"
        retry["subtype"] = "api_error"
        retry["uuid"] = "retry-1"
        retry["timestamp"] = stamp(4)
        retry["retryAttempt"] = 1
        retry["error"] = ["status": 529, "message": privateText, "formatted": "x"] as [String: Any]
        let result = outcomes([try real(at: 1, number: 1), try json(retry), try json(retry)])
        XCTAssertEqual(counts(result), [.succeeded: 1])
        // A request that retried and then succeeded is one success and no failure.
        let recovered = outcomes([try real(at: 1, number: 1), try json(retry), try real(at: 8, number: 2)])
        XCTAssertEqual(counts(recovered), [.succeeded: 2])
    }

    func testAMidStreamServerErrorKeepsItsPartialResponseAsOneSuccessAndIsOneFailure() throws {
        let result = outcomes([
            try userRecord(at: 0),
            try real(at: 1, number: 1, stop: nil),
            try failure(at: 3, uuid: "mid", status: nil, text: "API Error: Server error mid-response. The response above may be incomplete.")
        ])
        XCTAssertEqual(result.map(\.kind), [.succeeded, .serverError])
        XCTAssertEqual(Set(result.map(\.dedupeKey)).count, 2)
    }

    func testErrorTextIsNeverKept() throws {
        let result = outcomes([
            try real(at: 1, number: 1),
            try failure(at: 2, uuid: "f", status: 529, text: "\(privateText) is experiencing high load")
        ])
        XCTAssertEqual(result.count, 2)
        XCTAssertFalse(String(describing: result).contains(privateText))
        XCTAssertFalse(String(describing: result).contains("PRIVATE_RESPONSE"))
    }

    // MARK: Successes

    func testEveryDistinctRealResponseIsASuccessBeforeTheSpeedFilter() throws {
        let result = outcomes([
            try userRecord(at: 0),
            // Short, tool-call-only and very slow responses all count; the speed filter would drop them.
            try real(at: 1, number: 1, output: 5, stop: "tool_use"),
            try real(at: 3, number: 2, output: 20, stop: "tool_use"),
            try real(at: 4, number: 2, output: 25, stop: "tool_use"),
            try real(at: 5, number: 3, output: 250, stop: "tool_use"),
            try real(at: 2_000, number: 4, output: 400, stop: "end_turn")
        ])
        XCTAssertEqual(counts(result), [.succeeded: 4], "records sharing one message id are one response")
        XCTAssertEqual(Set(result.map(\.model)), ["claude-opus-5-5"])
        XCTAssertEqual(result.map(\.occurredAt), [1, 4, 5, 2_000].map { base.addingTimeInterval($0) }, "the response's last record closes it")
    }

    func testSyntheticAndModellessOrProviderlessRecordsAreNotResponses() throws {
        let result = outcomes([
            try real(at: 1, number: 1, model: "<synthetic>"),
            try real(at: 2, number: 2, requestID: nil),
            try real(at: 3, number: 3, model: "not a model name"),
            try real(at: 4, number: 4)
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.dedupeKey, outcomes([try real(at: 4, number: 4)]).first?.dedupeKey)
    }

    func testAResponseCutOffByAnInterruptionIsNotCounted() throws {
        var interrupt = envelope(sidechain: false)
        interrupt["type"] = "user"
        interrupt["uuid"] = "interrupt"
        interrupt["parentUuid"] = "x"
        interrupt["timestamp"] = stamp(3)
        interrupt["message"] = ["role": "user", "content": "[Request interrupted by user]"]
        let result = outcomes([try userRecord(at: 0), try real(at: 1, number: 1, stop: nil), try json(interrupt)])
        XCTAssertTrue(result.isEmpty)
    }

    func testAReReadYieldsTheSameKeysAndAParserCountsAResponseOnce() throws {
        let lines = [
            try userRecord(at: 0), try real(at: 1, number: 1), try real(at: 1, number: 1),
            try failure(at: 5, uuid: "f", status: 500, text: "x")
        ]
        let first = outcomes(lines), second = outcomes(lines)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.map(\.dedupeKey), second.map(\.dedupeKey))
        XCTAssertFalse(first.map(\.dedupeKey).contains { $0.contains("synthetic-session") || $0.contains("record-1") }, "digests, not raw ids")
    }

    func testSubagentFilesCountWithTheirOwnEvidence() throws {
        let result = outcomes([
            try real(at: 1, number: 1, model: "claude-haiku-5", sidechain: true),
            try failure(at: 3, uuid: "f", status: 529, text: "x", sidechain: true)
        ], scope: .subagent)
        XCTAssertEqual(result.map(\.kind), [.succeeded, .overloaded])
        XCTAssertEqual(Set(result.map(\.model)), ["claude-haiku-5"])
        // A primary parser ignores sidechain records entirely.
        XCTAssertTrue(outcomes([try real(at: 1, number: 1, sidechain: true)]).isEmpty)
    }

    func testResetForgetsOutcomesAndEvidence() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "a")
        _ = parser.consume(line: try real(at: 1, number: 1))
        _ = parser.pollEnded(now: base, isFinal: true)
        parser.reset(sourceIdentity: "a")
        XCTAssertTrue(parser.drainRequestOutcomes().isEmpty)
        _ = parser.consume(line: try failure(at: 2, uuid: "f", status: 529, text: "x"))
        XCTAssertTrue(parser.drainRequestOutcomes().isEmpty, "no response seen since the reset, so no model")
    }

    func testOutcomesDoNotChangeTheTurnMetrics() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try userRecord(at: 0))
        _ = parser.consume(line: try real(at: 10, number: 1, output: 400, stop: "end_turn"))
        let metric = try XCTUnwrap(parser.pollEnded(now: base, isFinal: true))
        XCTAssertEqual(metric.outputTokens, 400)
        XCTAssertEqual(metric.responseCount, 1)
        XCTAssertEqual(parser.drainRequestOutcomes().count, 1)
    }
}

/// Request outcomes of Codex rollouts.
final class CodexRequestOutcomeTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func line(_ seconds: Double, _ type: String, _ payload: [String: Any]) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try JSONSerialization.data(withJSONObject: [
            "timestamp": formatter.string(from: epoch.addingTimeInterval(seconds)), "type": type, "payload": payload
        ] as [String: Any])
    }

    private func header(
        version: String? = "0.162.0", provider: String? = "openai", source: Any = "vscode", extra: [String: Any] = [:]
    ) throws -> Data {
        var payload: [String: Any] = ["id": "synthetic-session", "source": source]
        payload["cli_version"] = version
        payload["model_provider"] = provider
        payload.merge(extra) { _, new in new }
        return try line(0, "session_meta", payload)
    }

    private func context(_ turn: String = "turn-1", model: String = "gpt-5.5") throws -> Data {
        try line(0, "turn_context", ["turn_id": turn, "model": model, "effort": "high"])
    }

    private func usage(_ seconds: Double, response: String, output: Int = 5, turn: String = "turn-1") throws -> Data {
        try line(seconds, "token_usage_record", [
            "turn_id": turn, "response_id": response,
            "usage": ["input_tokens": 1, "output_tokens": output],
            "turn_token_usage": ["input_tokens": 1, "output_tokens": output]
        ])
    }

    private func complete(_ seconds: Double, turn: String = "turn-1", error: Any? = nil) throws -> Data {
        var payload: [String: Any] = ["type": "task_complete", "turn_id": turn, "duration_ms": seconds * 1_000]
        if let error { payload["error"] = error }
        return try line(seconds, "event_msg", payload)
    }

    private func failed(_ info: Any?) -> [String: Any] {
        var error: [String: Any] = ["message": privateText]
        error["codex_error_info"] = info
        return error
    }

    private func outcomes(_ lines: [Data]) -> [RequestOutcome] {
        var parser = CodexEventParser(sourceIdentity: "/tmp/rollout.jsonl")
        for line in lines { _ = parser.consume(line: line) }
        return parser.drainRequestOutcomes()
    }

    private func failureKinds(_ info: Any?, version: String? = "0.162.0") throws -> [RequestOutcome.Kind] {
        try outcomes([header(version: version), context(), complete(10, error: failed(info))]).map(\.kind)
    }

    func testTerminalErrorsAreClassifiedByTheirEnumAndStatus() throws {
        XCTAssertEqual(try failureKinds("server_overloaded"), [.overloaded])
        XCTAssertEqual(try failureKinds("internal_server_error"), [.serverError])
        XCTAssertEqual(try failureKinds(["http_connection_failed": ["http_status_code": 503]]), [.serverError])
        XCTAssertEqual(try failureKinds(["http_connection_failed": ["http_status_code": 502]]), [.serverError])
        XCTAssertEqual(try failureKinds(["response_too_many_failed_attempts": ["http_status_code": 500]]), [.serverError])
        XCTAssertEqual(try failureKinds(["response_stream_connection_failed": ["http_status_code": 504]]), [.serverError])
        for name in ["http_connection_failed", "response_too_many_failed_attempts", "response_stream_connection_failed"] {
            XCTAssertEqual(try failureKinds([name: ["http_status_code": 529]]), [.overloaded], "HTTP 529 is overloaded: \(name)")
        }
        // Not provider-side, or not decidable.
        XCTAssertEqual(try failureKinds(["http_connection_failed": ["http_status_code": 403]]), [])
        XCTAssertEqual(try failureKinds(["http_connection_failed": ["http_status_code": NSNull()]]), [], "a local connection failure")
        XCTAssertEqual(try failureKinds(["http_connection_failed": [:] as [String: Any]]), [])
        XCTAssertEqual(try failureKinds(["response_too_many_failed_attempts": ["http_status_code": 429]]), [])
        XCTAssertEqual(try failureKinds(["response_stream_disconnected": ["http_status_code": 503]]), [])
        for name in ["usage_limit_exceeded", "rate_limit_exceeded", "session_budget_exceeded", "unauthorized", "bad_request",
                     "context_window_exceeded", "cyber_policy", "sandbox_error", "other", "http_connection_failed"] {
            XCTAssertEqual(try failureKinds(name), [], name)
        }
        XCTAssertEqual(try failureKinds(nil), [])
        XCTAssertEqual(try failureKinds(NSNull()), [])
    }

    func testAFailureCarriesTheTurnsModelAndTheCompletionTime() throws {
        let result = try outcomes([header(), context(model: "gpt-5.5"), complete(42, error: failed("server_overloaded"))])
        let outcome = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(outcome.model, "gpt-5.5")
        XCTAssertEqual(outcome.provider, "openai")
        XCTAssertEqual(outcome.client, "codex")
        XCTAssertEqual(outcome.parserVersion, "codex-rollout-v2")
        XCTAssertEqual(outcome.clientVersion, "0.162.0")
        XCTAssertEqual(outcome.occurredAt, epoch.addingTimeInterval(42))
        XCTAssertFalse(String(describing: result).contains(privateText))
    }

    func testAFailedTurnWithoutOrWithConflictingModelsIsDropped() throws {
        XCTAssertTrue(try outcomes([header(), complete(10, error: failed("server_overloaded"))]).isEmpty)
        let ambiguous = try outcomes([
            header(), context(model: "gpt-5.5"), context(model: "gpt-5.4"), complete(10, error: failed("server_overloaded"))
        ])
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testOnlyRolloutsFrom0145RecordOutcomes() throws {
        for version in ["0.145.0", "0.145.1", "0.146.0-alpha.1", "0.200.3", "1.0.0", "0.162.0+build.7"] {
            XCTAssertEqual(try failureKinds("server_overloaded", version: version), [.overloaded], version)
        }
        for version: String? in ["0.144.9", "0.144.99", "0.86.0", "0.145.0-alpha.3", "0.145", "garbage", "", "v0.162.0", "0.162.0.1", nil] {
            XCTAssertEqual(try failureKinds("server_overloaded", version: version), [], version ?? "nil")
        }
        // An old rollout contributes no successes either: they would be counted against invisible failures.
        let old = try outcomes([header(version: "0.144.9"), context(), usage(5, response: "r1")])
        XCTAssertTrue(old.isEmpty)
        let semantic = try outcomes([header(version: "0.9.0"), context(), usage(5, response: "r1")])
        XCTAssertTrue(semantic.isEmpty, "0.9 is older than 0.145 numerically as well as in text")
    }

    func testOnlyOpenAIRolloutsAreCounted() throws {
        for provider: String? in ["ollama", "azure", "custom", nil] {
            let result = try outcomes([header(provider: provider), context(), usage(5, response: "r1"), complete(10, error: failed("server_overloaded"))])
            XCTAssertTrue(result.isEmpty, provider ?? "nil")
        }
    }

    func testEveryTokenUsageRecordIsASuccessIncludingShortResponses() throws {
        let result = try outcomes([
            header(), line(0, "event_msg", ["type": "task_started", "turn_id": "turn-1"]), context(),
            usage(2, response: "r1", output: 3),
            usage(4, response: "r2", output: 4_000),
            usage(4, response: "r2", output: 4_000),
            usage(9, response: "r3", output: 250),
            line(10, "event_msg", ["type": "token_count", "turn_id": "turn-1", "info": ["total_token_usage": ["output_tokens": 1]]])
        ])
        XCTAssertEqual(result.map(\.kind), [.succeeded, .succeeded, .succeeded], "token_count is not a response; a repeated response id counts once")
        XCTAssertEqual(Set(result.map(\.dedupeKey)).count, 3)
        XCTAssertEqual(result.map(\.occurredAt), [2, 4, 9].map { epoch.addingTimeInterval($0) })
    }

    func testAResponseWhoseRequestWasNotSeenStillCountsUnderOneKey() throws {
        // A reader that joined mid-turn saw no trigger, so response speed ignores the response; the request was made.
        let result = try outcomes([header(), context(), usage(2, response: "r1"), usage(2, response: "r1")])
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(Set(result.map(\.dedupeKey)).count, 1)
    }

    func testAFailedTurnAfterSuccessfulResponsesCountsBoth() throws {
        let result = try outcomes([
            header(), context(), usage(2, response: "r1"), usage(5, response: "r2"), complete(10, error: failed("internal_server_error"))
        ])
        XCTAssertEqual(counts(result), [.succeeded: 2, .serverError: 1])
    }

    func testRepeatedCompletionOfOneTurnHasOneKey() throws {
        let result = try outcomes([header(), context(), complete(10, error: failed("server_overloaded")), complete(10, error: failed("server_overloaded"))])
        XCTAssertEqual(Set(result.map(\.dedupeKey)).count, 1)
    }

    func testSpawnedChildrenCountAndApprovalReviewSessionsDoNot() throws {
        let child = try outcomes([
            header(source: ["subagent": ["thread_spawn": ["parent_thread_id": "p"]]], extra: ["session_id": "root"]),
            context(), usage(2, response: "r1"), complete(10, error: failed("server_overloaded"))
        ])
        XCTAssertEqual(counts(child), [.succeeded: 1, .overloaded: 1])
        let review = try outcomes([
            header(source: ["subagent": ["other": "guardian"]]), context(), usage(2, response: "r1"),
            complete(10, error: failed("server_overloaded"))
        ])
        XCTAssertTrue(review.isEmpty)
    }

    func testOutcomesDoNotChangeTheTurnMetrics() throws {
        var parser = CodexEventParser(sourceIdentity: "/tmp/rollout.jsonl")
        for data in try [header(), line(0, "event_msg", ["type": "task_started", "turn_id": "turn-1"]), context()] { _ = parser.consume(line: data) }
        _ = parser.consume(line: try line(10, "token_usage_record", [
            "turn_id": "turn-1", "response_id": "r1", "usage": ["output_tokens": 300],
            "turn_token_usage": ["output_tokens": 300]
        ]))
        let metric = try XCTUnwrap(parser.consume(line: try complete(10)))
        XCTAssertEqual(metric.outputTokens, 300)
        XCTAssertEqual(metric.responseCount, 1)
        XCTAssertEqual(parser.drainRequestOutcomes().count, 1)
    }
}

/// Request outcomes of Kimi Code wire logs.
final class KimiRequestOutcomeTests: XCTestCase {
    private func failedTurn(code: String, status: Int? = nil, provider: String? = "kimi", model: String? = "k2d8-preview") -> [Data] {
        [KimiLog.prompt(at: 0)]
            + KimiLog.step("1", 1, begin: 1, end: 2, finish: "error", model: model, provider: provider)
            + [KimiLog.stepInterrupted(1, at: 2.1), KimiLog.turnFailed(1, code: code, status: status, at: 2.2),
               KimiLog.agentTurnEnded(1, outcome: "failed", at: 2.3), KimiLog.promptCompleted(at: 2.4)]
    }

    func testOverloadedAndServerErrorsAreClassifiedFromTheTurnEndError() {
        let overloaded = KimiWireParser.parse(failedTurn(code: "provider.overloaded", status: 529)).outcomes
        XCTAssertEqual(overloaded.map(\.kind), [.overloaded])
        XCTAssertEqual(overloaded.first?.model, "k2d8-preview")
        XCTAssertEqual(overloaded.first?.provider, "moonshot")
        XCTAssertEqual(overloaded.first?.client, "kimi-code")
        XCTAssertEqual(overloaded.first?.parserVersion, "kimi-wire-v1")
        XCTAssertEqual(overloaded.first?.clientVersion, "unknown")
        XCTAssertEqual(overloaded.first?.occurredAt, KimiLog.date(2.2))
        XCTAssertEqual(KimiWireParser.parse(failedTurn(code: "provider.api_error", status: 502)).outcomes.map(\.kind), [.serverError])
        XCTAssertEqual(KimiWireParser.parse(failedTurn(code: "provider.api_error", status: 500)).outcomes.map(\.kind), [.serverError])
        XCTAssertEqual(KimiWireParser.parse(failedTurn(code: "provider.overloaded")).outcomes.map(\.kind), [.overloaded], "no status needed")
        XCTAssertEqual(KimiWireParser.parse(failedTurn(code: "provider.api_error", status: 529)).outcomes.map(\.kind), [.overloaded], "HTTP 529 is overloaded under any code")
    }

    func testEveryOtherFailureIsDropped() {
        let cases: [(String, Int?)] = [
            ("provider.rate_limit", 429), ("provider.auth_error", 403), ("provider.connection_error", nil), ("context.overflow", nil),
            ("provider.filtered", nil), ("internal", nil), ("auth.login_required", nil), ("provider.api_error", 429),
            ("provider.api_error", 400), ("provider.api_error", 404), ("provider.api_error", nil),
            ("provider.api_error", 600)
        ]
        for (code, status) in cases {
            XCTAssertTrue(KimiWireParser.parse(failedTurn(code: code, status: status)).outcomes.isEmpty, "\(code) \(status.map(String.init) ?? "-")")
        }
    }

    func testTheFourRecordsOfOneFailedTurnAreOneOutcome() {
        let parsed = KimiWireParser.parse(failedTurn(code: "provider.overloaded", status: 529))
        XCTAssertEqual(parsed.outcomes.count, 1)
        XCTAssertTrue(parsed.metrics.isEmpty)
    }

    func testRetryRecordsAreNeverCounted() {
        let lines = [KimiLog.prompt(at: 0), KimiLog.begin("1", 1, at: 1), KimiLog.request("1", 1, at: 1.001),
                     KimiLog.stepRetrying("1", at: 2), KimiLog.stepRetrying("1", at: 3), KimiLog.request("1", 1, at: 3.1),
                     KimiLog.end("1", 1, at: 6, finish: "end_turn")]
        let parsed = KimiWireParser.parse(lines)
        XCTAssertEqual(parsed.outcomes.map(\.kind), [.succeeded])
    }

    func testAFailureBeforeAnyRequestOrWithAnotherProviderHasNoModelAndIsDropped() {
        let early = [KimiLog.prompt(at: 0), KimiLog.begin("1", 1, at: 1), KimiLog.turnFailed(1, code: "provider.overloaded", at: 1.2)]
        XCTAssertTrue(KimiWireParser.parse(early).outcomes.isEmpty)
        XCTAssertTrue(KimiWireParser.parse(failedTurn(code: "provider.overloaded", provider: "openai")).outcomes.isEmpty)
        XCTAssertTrue(KimiWireParser.parse(failedTurn(code: "provider.overloaded", model: nil)).outcomes.isEmpty)
    }

    func testTheDesktopAppWritesNoStepEndForAFailedCall() {
        // begin, request, then only the turn's end: the open step's request names the model.
        let lines = [KimiLog.prompt(at: 0), KimiLog.begin("1", 1, at: 1), KimiLog.request("1", 1, at: 1.001),
                     KimiLog.turnFailed(1, code: "provider.api_error", status: 503, at: 2)]
        XCTAssertEqual(KimiWireParser.parse(lines).outcomes.map(\.kind), [.serverError])
    }

    func testSuccessfulStepsAreCountedBeforeTheSpeedFilterInAnyTurn() {
        // 30 output tokens in one second: far below the response filter, still a succeeded request.
        let measured = [KimiLog.prompt(at: 0)] + KimiLog.step("1", 1, begin: 1, end: 2, finish: "tool_use", output: 30)
            + KimiLog.step("1", 2, begin: 3, end: 20, finish: "end_turn", output: 400)
        let parsed = KimiWireParser.parse(measured)
        XCTAssertEqual(parsed.outcomes.map(\.kind), [.succeeded, .succeeded])
        XCTAssertEqual(parsed.metrics.count, 1, "the turn is unchanged")
        XCTAssertEqual(Set(parsed.outcomes.map(\.dedupeKey)).count, 2)
        // A turn joined mid-file is unmeasured but its requests were made.
        let joined = KimiWireParser.parse(KimiLog.step("1", 3, begin: 1, end: 5, finish: "end_turn", output: 300), startedMidFile: true)
        XCTAssertTrue(joined.metrics.isEmpty)
        XCTAssertEqual(joined.outcomes.map(\.kind), [.succeeded])
        // Subagent steps are requests too.
        let sub = KimiWireParser.parse(
            [KimiLog.prompt(at: 0)] + KimiLog.step("1", 1, begin: 1, end: 5, finish: "end_turn", output: 300),
            scope: .subagent, path: KimiLog.subagentPath
        )
        XCTAssertEqual(sub.outcomes.map(\.kind), [.succeeded])
        XCTAssertNotEqual(sub.outcomes.first?.dedupeKey, KimiWireParser.parse(
            [KimiLog.prompt(at: 0)] + KimiLog.step("1", 1, begin: 1, end: 5, finish: "end_turn", output: 300)
        ).outcomes.first?.dedupeKey, "the agent folder keeps subagent keys apart")
    }

    func testFailedStepsAndStepsWithoutUsageOrModelAreNotSuccesses() {
        let noModel = KimiWireParser.parse([KimiLog.prompt(at: 0)] + KimiLog.step("1", 1, begin: 1, end: 5, finish: "end_turn", model: nil))
        XCTAssertTrue(noModel.outcomes.isEmpty)
        let otherProvider = KimiWireParser.parse([KimiLog.prompt(at: 0)] + KimiLog.step("1", 1, begin: 1, end: 5, finish: "end_turn", provider: "openai"))
        XCTAssertTrue(otherProvider.outcomes.isEmpty)
        let errored = KimiWireParser.parse([KimiLog.prompt(at: 0)] + KimiLog.step("1", 1, begin: 1, end: 5, finish: "error"))
        XCTAssertTrue(errored.outcomes.isEmpty)
        var unusable = KimiLog.step("1", 1, begin: 1, end: 5, finish: "end_turn")
        unusable[2] = KimiLog.end("1", 1, at: 5, finish: "end_turn", usage: ["output": "x"])
        XCTAssertTrue(KimiWireParser.parse([KimiLog.prompt(at: 0)] + unusable).outcomes.isEmpty)
    }

    func testErrorTextIsNeverKept() {
        let parsed = KimiWireParser.parse(failedTurn(code: "provider.overloaded", status: 529))
        XCTAssertFalse(String(describing: parsed.outcomes).contains(privateText))
    }
}

/// Request outcomes of OpenCode's database.
final class OpenCodeRequestOutcomeTests: XCTestCase {
    private var scratch: URL!
    private typealias Message = SyntheticOpenCodeMessage

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tokrate-opencode-outcomes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var now: Date { SyntheticOpenCodeDatabase.date(10_000) }
    private var bumps = 0

    /// A database of its own, holding one session and its prompt.
    private func makeDatabase() throws -> (database: SyntheticOpenCodeDatabase, root: URL) {
        let root = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let database = try SyntheticOpenCodeDatabase(url: OpenCodeMonitor.databaseURL(root: root))
        try database.addSession("ses1")
        try database.user("msg_u1", session: "ses1", at: 0)
        return (database, root)
    }

    private func bump(_ database: SyntheticOpenCodeDatabase) throws {
        bumps += 1
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(Double(bumps))], ofItemAtPath: database.url.path)
    }

    private func assistant(
        _ id: String, session: String = "ses1", created: Double = 1, completed: Double? = 5, output: Int? = 40,
        model: String? = "claude-sonnet-4-5", provider: String? = "anthropic", errorName: String? = nil, errorStatus: Int? = nil,
        finish: String? = "stop"
    ) -> Message {
        Message(
            id: id, session: session, parentID: "msg_u1", created: created, completed: completed, output: output, reasoning: 0,
            input: 100, cacheRead: 0, cacheWrite: 0, model: model, provider: provider, finish: errorName == nil ? finish : nil,
            errorName: errorName, errorStatus: errorStatus
        )
    }

    private func outcomes(of messages: Message..., liveSince: Date = .distantPast) async throws -> [RequestOutcome] {
        let (database, root) = try makeDatabase()
        for message in messages { try database.put(message) }
        return await OpenCodeMonitor(root: root, liveSince: liveSince).poll(now: now).outcomes
    }

    func testApiErrorsAreClassifiedByStatus() async throws {
        let cases: [(name: String?, status: Int?, kind: RequestOutcome.Kind?)] = [
            ("APIError", 529, .overloaded), ("APIError", 500, .serverError), ("APIError", 503, .serverError),
            ("APIError", 599, .serverError), ("APIError", 429, nil), ("APIError", 403, nil), ("APIError", 400, nil),
            ("APIError", 404, nil), ("APIError", 600, nil), ("APIError", nil, nil),
            ("MessageAbortedError", nil, nil), ("MessageAbortedError", 529, nil), ("UnknownError", 500, nil),
            ("ProviderAuthError", nil, nil), ("ContextOverflowError", 413, nil), ("ContentFilterError", nil, nil)
        ]
        for entry in cases {
            let result = try await outcomes(of: assistant("msg_a1", output: 0, errorName: entry.name, errorStatus: entry.status))
            XCTAssertEqual(result.map(\.kind), entry.kind.map { [$0] } ?? [], "\(entry.name ?? "-") \(entry.status.map(String.init) ?? "-")")
        }
    }

    func testAFailureUsesTheMessagesOwnModelProviderAndTime() async throws {
        let result = try await outcomes(of: assistant(
            "msg_a1", created: 3, completed: 7, output: 0, model: "gpt-5.5", provider: "openai", errorName: "APIError", errorStatus: 529
        ))
        let outcome = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(outcome.model, "gpt-5.5")
        XCTAssertEqual(outcome.provider, "openai")
        XCTAssertEqual(outcome.client, "opencode")
        XCTAssertEqual(outcome.parserVersion, "opencode-db-v1")
        XCTAssertEqual(outcome.clientVersion, "1.18.31")
        XCTAssertEqual(outcome.occurredAt, SyntheticOpenCodeDatabase.date(7))
        XCTAssertFalse(String(describing: result).contains(SyntheticOpenCodeDatabase.privateText))
        // A failed message that never got a completion time is dated by its creation.
        let open = try await outcomes(of: assistant("msg_a2", created: 3, completed: nil, output: 0, errorName: "APIError", errorStatus: 500))
        XCTAssertEqual(open.first?.occurredAt, SyntheticOpenCodeDatabase.date(3))
    }

    func testEveryCompletedMessageWithoutAnErrorIsASuccessEvenWhenShort() async throws {
        let (database, root) = try makeDatabase()
        try database.put(assistant("msg_a1", created: 1, completed: 2, output: 3, finish: "tool-calls"))
        try database.put(assistant("msg_a2", created: 3, completed: 9, output: 500))
        try database.put(assistant("msg_a3", created: 10, completed: nil, output: 0, finish: nil))
        let monitor = OpenCodeMonitor(root: root, liveSince: .distantPast)
        let first = await monitor.poll(now: now).outcomes
        XCTAssertEqual(first.map(\.kind), [.succeeded, .succeeded], "a message still running is not an outcome yet")

        try database.put(assistant("msg_a3", created: 10, completed: 12, output: 20))
        try bump(database)
        let second = await monitor.poll(now: now).outcomes
        XCTAssertEqual(second.count, 1, "only the message that completed since")
        try bump(database)
        let third = await monitor.poll(now: now).outcomes
        XCTAssertTrue(third.isEmpty, "each message once")
    }

    func testGatewaysLocalServersAndOddModelsAreDropped() async throws {
        let result = try await outcomes(
            of: assistant("msg_a1", provider: "openrouter"),
            assistant("msg_a2", output: 0, provider: "omlx", errorName: "APIError", errorStatus: 500),
            assistant("msg_a3", model: "moonshotai/kimi-k2.5", provider: "anthropic"),
            assistant("msg_a4", provider: nil),
            assistant("msg_a5", model: nil),
            assistant("msg_ok", model: "gemini-3-pro", provider: "google")
        )
        XCTAssertEqual(result.map(\.model), ["gemini-3-pro"])
        XCTAssertEqual(result.map(\.provider), ["google"])
    }

    func testSubagentSessionsCountAndOutcomesBeforeLaunchDoNot() async throws {
        let (database, root) = try makeDatabase()
        try database.addSession("ses2", parent: "ses1")
        try database.put(assistant("msg_sub", session: "ses2", created: 1, completed: 5))
        try database.put(assistant("msg_main", created: 1, completed: 5))
        let atLaunch = await OpenCodeMonitor(root: root, liveSince: SyntheticOpenCodeDatabase.date(5)).poll(now: now).outcomes
        XCTAssertEqual(atLaunch.count, 2, "finished at or after the launch time, subagent session included")
        let afterwards = await OpenCodeMonitor(root: root, liveSince: SyntheticOpenCodeDatabase.date(6)).poll(now: now).outcomes
        XCTAssertTrue(afterwards.isEmpty, "history is not counted")
    }

    func testSessionsBelowTheVersionFloorProduceNoOutcomes() async throws {
        let (database, root) = try makeDatabase()
        try database.addSession("old", version: "1.13.9")
        try database.addSession("odd", version: "1.14.0-beta")
        try database.addSession("edge", version: "1.14.0")
        try database.addSession("old-child", parent: "old", version: "1.13.9")
        try database.addSession("new-child", parent: "ses1", version: "1.18.31")
        for session in ["old", "odd", "edge", "old-child", "new-child"] {
            try database.put(assistant("ok_\(session)", session: session))
            try database.put(assistant("err_\(session)", session: session, output: 0, errorName: "APIError", errorStatus: 529))
        }
        let result = await OpenCodeMonitor(root: root, liveSince: .distantPast).poll(now: now).outcomes
        XCTAssertEqual(
            result.map { "\($0.clientVersion) \($0.kind)" }.sorted(),
            ["1.14.0 overloaded", "1.14.0 succeeded", "1.18.31 overloaded", "1.18.31 succeeded"],
            "only the floor session and the supported subagent session count"
        )
        // A message whose session row is unknown is not measured either.
        try database.put(assistant("ok_orphan", session: "missing"))
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(99)], ofItemAtPath: database.url.path)
        let again = await OpenCodeMonitor(root: root, liveSince: .distantPast).poll(now: now).outcomes
        XCTAssertEqual(again.count, 4)
    }

    func testOutcomesDoNotChangeTheTurnsOrResponses() async throws {
        let (database, root) = try makeDatabase()
        try database.put(assistant("msg_a1", created: 1, completed: 11, output: 400))
        let update = await OpenCodeMonitor(root: root, liveSince: .distantPast).poll(now: now)
        XCTAssertEqual(update.metrics.count, 1)
        XCTAssertEqual(update.responses.count, 1)
        XCTAssertEqual(update.outcomes.count, 1)
    }
}
