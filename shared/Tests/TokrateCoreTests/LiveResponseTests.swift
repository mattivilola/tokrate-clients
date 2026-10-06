import Foundation
import TokrateCore
import XCTest

final class LiveResponseTests: XCTestCase {
    private let completedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func grokTurn(
        id: String = "turn-1", model: String? = "grok-4.7", sourceKind: String? = "primary",
        responseTokens: Int? = 6_000, responseSeconds: Double? = 75, responseCount: Int? = 4
    ) -> TurnMetric {
        TurnMetric(
            id: id, completedAt: completedAt, model: model, outputTokens: 7_000, durationSeconds: 200,
            codexTTFTSeconds: nil, turnThroughputTPS: 35, client: "grok-build", clientVersion: nil,
            parserVersion: "grok-session-v2", metricVersion: "grok-observed-work-turn-v1", sourceKind: sourceKind,
            provider: "unknown", reasoningEffort: "high",
            responseOutputTokens: responseTokens, responseDurationSeconds: responseSeconds, responseCount: responseCount
        )
    }

    func testAQualifyingPrimaryTurnBecomesOneLiveResponseWithTheTurnIdentity() throws {
        let response = try XCTUnwrap(LiveResponse(turn: grokTurn()))
        XCTAssertEqual(response.id, "turn-1")
        XCTAssertEqual(response.model, "grok-4.7")
        XCTAssertEqual(response.provider, "unknown")
        XCTAssertEqual(response.client, "grok-build")
        XCTAssertEqual(response.sourceKind, "primary")
        XCTAssertEqual(response.metricVersion, "grok-observed-work-turn-v1")
        XCTAssertEqual(response.reasoningEffort, "high")
        XCTAssertEqual(response.completedAt, completedAt)
        XCTAssertEqual(response.outputTokens, 6_000, "the response tokens, not the whole turn's")
        XCTAssertEqual(response.durationSeconds, 75)
        XCTAssertEqual(response.tokensPerSecond, 80, accuracy: 0.001)
    }

    func testTurnsThatDoNotQualifyAsAResponseAreRejected() {
        XCTAssertNil(LiveResponse(turn: grokTurn(responseTokens: nil, responseSeconds: nil, responseCount: nil)), "no response timing")
        XCTAssertNil(LiveResponse(turn: grokTurn(model: nil)), "no model")
        XCTAssertNil(LiveResponse(turn: grokTurn(responseTokens: 150, responseSeconds: 5)), "below 200 tokens")
        XCTAssertNil(LiveResponse(turn: grokTurn(responseTokens: 600, responseSeconds: 601)), "over 600 s")
        XCTAssertNil(LiveResponse(turn: grokTurn(responseTokens: 6_000, responseSeconds: 2)), "over 2,000 tok/s")
        XCTAssertNotNil(LiveResponse(turn: grokTurn(responseTokens: 200, responseSeconds: 600)), "the bounds themselves qualify")
    }

    func testSubagentAndUnclassifiedTurnsAreExcluded() {
        XCTAssertNil(LiveResponse(turn: grokTurn(sourceKind: "subagent")))
        XCTAssertNil(LiveResponse(turn: grokTurn(sourceKind: nil)))
        XCTAssertNil(LiveResponse(turn: grokTurn(sourceKind: "unknown")))
    }
}
