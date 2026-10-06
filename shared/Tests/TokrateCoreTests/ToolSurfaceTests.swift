import Foundation
import TokrateCore
import XCTest

final class ToolSurfaceTests: XCTestCase {
    func testCodexOriginatorMapping() {
        let expected: [(String?, ToolSurface?)] = [
            ("Codex Desktop", .desktop), ("codex_work_desktop", .desktop),
            ("codex_cli_rs", .cli), ("codex-tui", .cli), ("codex_tui", .cli),
            ("codex_vscode", .ide), ("codex_jetbrains", .ide), ("Cursor", .ide), ("windsurf-codex", .ide),
            ("codex_exec", .sdk), ("codex_sdk_ts", .sdk), ("codex_sdk", .sdk),
            ("vibe-codex-executor", .other), ("buzz-acp", .other), ("t3code_desktop", .other), ("bb", .other),
            ("", nil), ("   ", nil), (nil, nil)
        ]
        for (originator, surface) in expected {
            XCTAssertEqual(ToolSurface.codex(originator: originator), surface, "originator \(originator ?? "nil")")
        }
    }

    func testCodexOriginatorIsTrimmedAndCaseInsensitive() {
        XCTAssertEqual(ToolSurface.codex(originator: "  CODEX DESKTOP\n"), .desktop)
        XCTAssertEqual(ToolSurface.codex(originator: "Codex_CLI_RS"), .cli)
        XCTAssertEqual(ToolSurface.codex(originator: "CODEX_EXEC"), .sdk)
    }

    func testClaudeEntrypointMapping() {
        let expected: [(String?, ToolSurface?)] = [
            ("cli", .cli), ("claude-desktop", .desktop),
            ("claude-vscode", .ide), ("claude-jetbrains", .ide), ("cursor", .ide), ("windsurf", .ide), ("ide", .ide),
            ("sdk-ts", .sdk), ("sdk-py", .sdk), ("sdk-cli", .sdk),
            ("mcp", .other), ("remote", .other),
            ("", nil), (nil, nil)
        ]
        for (entrypoint, surface) in expected {
            XCTAssertEqual(ToolSurface.claude(entrypoint: entrypoint), surface, "entrypoint \(entrypoint ?? "nil")")
        }
        XCTAssertEqual(ToolSurface.claude(entrypoint: " CLI "), .cli)
    }

    func testRawValuesAreTheSharedCategories() {
        XCTAssertEqual(ToolSurface.allCases.map(\.rawValue), ["cli", "desktop", "ide", "sdk", "other"])
    }

    func testTurnMetricCodableRoundTripKeepsTheSurface() throws {
        for surface in ToolSurface.allCases {
            let metric = TurnMetric(
                id: "id", completedAt: Date(timeIntervalSince1970: 1_800_000_000), model: "m", outputTokens: 10,
                durationSeconds: 1, codexTTFTSeconds: nil, turnThroughputTPS: 10, surface: surface
            )
            let encoder = JSONEncoder(), decoder = JSONDecoder()
            encoder.dateEncodingStrategy = .iso8601
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(TurnMetric.self, from: encoder.encode(metric))
            XCTAssertEqual(decoded.surface, surface)
            XCTAssertEqual(decoded, metric)
            // The copy helpers forward it.
            XCTAssertEqual(metric.withDelegatedOutputTokens(5).surface, surface)
            XCTAssertEqual(metric.withoutResponseTiming().surface, surface)
        }
    }

    func testRecordWithoutTheKeyOrWithAnUnknownValueDecodesWithNilSurface() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func record(_ extra: String) -> Data {
            Data(#"{"id":"r","completedAt":"2026-10-03T20:00:00Z","outputTokens":100,"durationSeconds":10,"turnThroughputTPS":10\#(extra)}"#.utf8)
        }
        XCTAssertNil(try decoder.decode(TurnMetric.self, from: record("")).surface)
        XCTAssertNil(try decoder.decode(TurnMetric.self, from: record(#","surface":null"#)).surface)
        XCTAssertNil(try decoder.decode(TurnMetric.self, from: record(#","surface":"satellite""#)).surface)
        XCTAssertNil(try decoder.decode(TurnMetric.self, from: record(#","surface":42"#)).surface)
        XCTAssertEqual(try decoder.decode(TurnMetric.self, from: record(#","surface":"ide""#)).surface, .ide)
    }

    func testNilSurfaceIsOmittedFromStoredHistory() throws {
        let metric = TurnMetric(
            id: "id", completedAt: Date(timeIntervalSince1970: 1_800_000_000), model: "m", outputTokens: 10,
            durationSeconds: 1, codexTTFTSeconds: nil, turnThroughputTPS: 10
        )
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(metric), as: UTF8.self).contains("surface"))
    }
}
