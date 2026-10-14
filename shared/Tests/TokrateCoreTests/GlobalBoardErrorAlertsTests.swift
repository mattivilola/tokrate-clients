import Foundation
import XCTest
@testable import TokrateCore

/// Contract "Community error alerts (0.1.23)": `errors.alerts` decodes leniently and never fails the board.
final class GlobalBoardErrorAlertsTests: XCTestCase {
    private func board(errors: String?) -> Data {
        let tail = errors.map { #","errors":\#($0)"# } ?? ""
        return Data(#"{"schemaVersion":1,"collectionEnabled":true,"state":"ready","window":"24h","cohorts":[],"alerts":[]\#(tail)}"#.utf8)
    }

    private func alertJSON(_ model: String, contributors: Int = 3, extra: String = "") -> String {
        #"{"model":"\#(model)","provider":"anthropic","clients":["claude-code","codex"],"failingContributors":\#(contributors),"overloaded":4,"serverError":1,"firstFailureAt":"2026-10-13T10:00:00Z","lastFailureAt":"2026-10-13T10:12:30.500Z"\#(extra)}"#
    }

    private func decode(_ data: Data) throws -> GlobalBoard { try JSONDecoder().decode(GlobalBoard.self, from: data) }

    func testDecodesAlertFields() throws {
        let decoded = try decode(board(errors: #"{"alerts":[\#(alertJSON("claude-opus-5-5"))]}"#))
        let alert = try XCTUnwrap(decoded.errorAlerts.first)
        XCTAssertEqual(decoded.errorAlerts.count, 1)
        XCTAssertEqual(alert.model, "claude-opus-5-5")
        XCTAssertEqual(alert.provider, "anthropic")
        XCTAssertEqual(alert.clients, ["claude-code", "codex"])
        XCTAssertEqual(alert.failingContributors, 3)
        XCTAssertEqual(alert.overloaded, 4)
        XCTAssertEqual(alert.serverError, 1)
        XCTAssertEqual(alert.throttled, 0, "a server that does not send throttled reads as 0")
        XCTAssertEqual(alert.firstFailureAt, Date(timeIntervalSince1970: 1_791_885_600))
        XCTAssertEqual(alert.lastFailureAt, Date(timeIntervalSince1970: 1_791_885_600 + 750.5))
    }

    func testDecodesThrottledAndAThrottleOnlyAlert() throws {
        let withThrottled = try XCTUnwrap(decode(board(errors: #"{"alerts":[\#(alertJSON("m", extra: #","throttled":6"#))]}"#)).errorAlerts.first)
        XCTAssertEqual(withThrottled.throttled, 6)
        XCTAssertEqual(withThrottled.overloaded, 4)
        let only = #"{"model":"m","failingContributors":2,"throttled":3,"lastFailureAt":"2026-10-13T10:00:00Z"}"#
        let alert = try XCTUnwrap(decode(board(errors: #"{"alerts":[\#(only)]}"#)).errorAlerts.first)
        XCTAssertEqual([alert.overloaded, alert.serverError, alert.throttled], [0, 0, 3])
        let negative = #"{"model":"m","failingContributors":2,"throttled":-4,"lastFailureAt":"2026-10-13T10:00:00Z"}"#
        XCTAssertEqual(try decode(board(errors: #"{"alerts":[\#(negative)]}"#)).errorAlerts.first?.throttled, 0)
    }

    func testMissingErrorsOrAlertsDecodeAsNoAlerts() throws {
        XCTAssertEqual(try decode(board(errors: nil)).errorAlerts, [])
        XCTAssertEqual(try decode(board(errors: "{}")).errorAlerts, [])
        XCTAssertEqual(try decode(board(errors: #"{"alerts":null}"#)).errorAlerts, [])
        XCTAssertEqual(try decode(board(errors: #"{"alerts":[]}"#)).errorAlerts, [])
    }

    func testUnreadableErrorsNeverFailTheBoard() throws {
        for errors in [#""oops""#, "42", "[]", #"{"alerts":"none"}"#, #"{"alerts":{"model":"m"}}"#, "null"] {
            XCTAssertEqual(try decode(board(errors: errors)).errorAlerts, [], errors)
        }
    }

    func testAMalformedEntryIsSkippedWithoutFailingTheBoardOrItsNeighbours() throws {
        let entries = [
            alertJSON("first"),
            "7",
            #""text""#,
            "null",
            #"{"model":"no-count","lastFailureAt":"2026-10-13T10:00:00Z"}"#,
            #"{"model":"","failingContributors":2,"lastFailureAt":"2026-10-13T10:00:00Z"}"#,
            #"{"model":"bad-time","failingContributors":2,"lastFailureAt":"yesterday"}"#,
            #"{"model":"no-time","failingContributors":2}"#,
            #"{"model":"bad-type","failingContributors":"2","lastFailureAt":"2026-10-13T10:00:00Z"}"#,
            #"{"model":"bad-clients","failingContributors":2,"clients":"codex","lastFailureAt":"2026-10-13T10:00:00Z"}"#,
            alertJSON("second")
        ]
        let decoded = try decode(board(errors: #"{"alerts":[\#(entries.joined(separator: ","))]}"#))
        XCTAssertEqual(decoded.errorAlerts.map(\.model), ["first", "second"])
    }

    func testOptionalFieldsDefaultAndNegativeCountsReadAsZero() throws {
        let json = #"{"model":"m","failingContributors":-2,"overloaded":-1,"lastFailureAt":"2026-10-13T10:00:00Z","firstFailureAt":"not a time"}"#
        let alert = try XCTUnwrap(decode(board(errors: #"{"alerts":[\#(json)]}"#)).errorAlerts.first)
        XCTAssertEqual(alert.provider, "")
        XCTAssertEqual(alert.clients, [])
        XCTAssertEqual(alert.failingContributors, 0)
        XCTAssertEqual(alert.overloaded, 0)
        XCTAssertEqual(alert.serverError, 0)
        XCTAssertNil(alert.firstFailureAt)
    }

    func testAtMostTwentyAlertsAreKept() throws {
        let entries = (0..<35).map { alertJSON("m\($0)") }
        let decoded = try decode(board(errors: #"{"alerts":[\#(entries.joined(separator: ","))]}"#))
        XCTAssertEqual(decoded.errorAlerts.count, 20)
        XCTAssertEqual(decoded.errorAlerts.first?.model, "m0")
        XCTAssertEqual(decoded.errorAlerts.last?.model, "m19")
    }

    func testMalformedEntriesDoNotCountTowardsTheCap() throws {
        let entries = (0..<5).map { _ in "1" } + (0..<25).map { alertJSON("m\($0)") }
        let decoded = try decode(board(errors: #"{"alerts":[\#(entries.joined(separator: ","))]}"#))
        XCTAssertEqual(decoded.errorAlerts.count, 20)
    }

    func testOlderBoardsStillDecodeUnchanged() throws {
        let legacy = Data(#"{"schemaVersion":1,"collectionEnabled":true,"state":"early_data","window":"15m","cohorts":[{"id":"legacy","model":"gpt-test","provider":"openai","contributors":1,"turns":1}],"alerts":[{"cohortId":"legacy","state":"slow","metric":"throughput","changePercent":-40,"model":"gpt-test"}]}"#.utf8)
        let decoded = try decode(legacy)
        XCTAssertEqual(decoded.cohorts.count, 1)
        XCTAssertEqual(decoded.alerts.count, 1)
        XCTAssertEqual(decoded.alerts.first?.metric, "throughput")
        XCTAssertEqual(decoded.errorAlerts, [])
        XCTAssertNil(decoded.generatedAt)
        XCTAssertNil(decoded.methodology)
    }
}
