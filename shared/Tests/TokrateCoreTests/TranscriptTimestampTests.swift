import Foundation
@testable import TokrateCore
import XCTest

final class TranscriptTimestampTests: XCTestCase {
    /// The behaviour before the hand parser: whole-second and fractional `ISO8601DateFormatter` passes.
    private func reference(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private func seconds(_ string: String) -> Double? {
        TranscriptTimestamp.parse(string)?.timeIntervalSince1970
    }

    func testTheShapesRealTranscriptsUse() {
        let table: [(String, Double)] = [
            // Codex rollout `timestamp`, Claude Code `timestamp`, Grok Build `ts` and `endedAt` in the fixtures.
            ("2026-10-06T05:37:58.123Z", 1_791_265_078.123),
            ("2026-09-28T11:03:57.888Z", 1_790_593_437.888),
            ("2026-10-03T20:00:25.000Z", 1_791_057_625),
            // Grok Build usage.json `updatedAt` / `endedAt`: microseconds and a numeric offset.
            ("2026-09-24T07:45:59.729982+00:00", 1_790_235_959.729982),
            ("2026-09-24T07:39:17.404986+00:00", 1_790_235_557.404986),
            // Whole seconds, as the test fixtures write them.
            ("2026-10-03T20:00:26Z", 1_791_057_626)
        ]
        for (string, expected) in table {
            XCTAssertEqual(try XCTUnwrap(seconds(string)), expected, accuracy: 1e-6, string)
        }
    }

    func testOffsetsAreSubtractedFromTheLocalTime() {
        XCTAssertEqual(seconds("2026-10-06T05:37:58+02:00"), 1_791_257_878)
        XCTAssertEqual(seconds("2026-10-06T05:37:58-05:30"), 1_791_284_878)
        XCTAssertEqual(seconds("2026-10-06T05:37:58-0530"), 1_791_284_878)
        XCTAssertEqual(seconds("2026-10-06T05:37:58+0200"), 1_791_257_878)
        XCTAssertEqual(seconds("2026-10-06T05:37:58-00:00"), 1_791_265_078)
        // A local time that crosses midnight and the year.
        XCTAssertEqual(seconds("2026-01-01T01:00:00+02:00"), seconds("2025-12-31T23:00:00Z"))
    }

    func testFractionsOfOneToNineDigits() throws {
        for digits in 1...9 {
            let fraction = String(repeating: "5", count: digits)
            let string = "2026-10-06T05:37:58.\(fraction)Z"
            let expected = 1_791_265_078 + Double("0.\(fraction)")!
            XCTAssertEqual(try XCTUnwrap(seconds(string)), expected, accuracy: 1e-6, string)
        }
        // Sub-millisecond precision is kept (the formatter itself stops at milliseconds).
        XCTAssertEqual(try XCTUnwrap(seconds("2026-10-06T05:37:58.000123Z")), 1_791_265_078.000123, accuracy: 1e-6)
    }

    func testLeapYears() {
        XCTAssertEqual(seconds("2028-02-29T12:00:00Z"), 1_835_438_400)
        XCTAssertEqual(seconds("2000-02-29T00:00:00Z"), 951_782_400)
        XCTAssertEqual(seconds("2028-03-01T00:00:00Z"), try XCTUnwrap(seconds("2028-02-29T00:00:00Z")) + 86_400)
        XCTAssertEqual(seconds("2024-12-31T23:59:59Z"), 1_735_689_599)
        XCTAssertEqual(seconds("1969-12-31T23:59:59Z"), -1)
        XCTAssertEqual(seconds("1970-01-01T00:00:00Z"), 0)
    }

    func testInvalidStringsAreRejected() {
        let invalid = [
            "", "not a date", "2026-10-06", "2026-10-06T05:37:58", "2026-10-06T05:37Z", "2026-10-06 05:37:58Z",
            "2026-13-06T05:37:58Z", "2026-00-06T05:37:58Z", "2026-10-32T05:37:58Z", "2026-10-00T05:37:58Z",
            "2026-10-06T25:00:00Z", "2026-10-06T23:60:00Z", "2026-10-06T23:59:60Z",
            "2026-10-06T05:37:58.Z", "2026-10-06T05:37:58,123Z", "20261006T053758Z", "+2026-10-06T05:37:58Z"
        ]
        for string in invalid {
            XCTAssertNil(TranscriptTimestamp.parse(string), string.debugDescription)
        }
    }

    /// Whatever the formatter accepted before still parses, to the same instant: the hand parser only
    /// takes the strict shape and hands every other string to the formatter.
    func testStringsOnlyTheFormatterAcceptsStillParseTheSame() {
        let lenient = [
            "2026-10-06T05:37:58Zjunk", "2026-10-06T05:37:58Z\n", " 2026-10-06T05:37:58Z", "2026-02-30T05:37:58Z",
            "1900-02-29T00:00:00Z", "2026-10-06T24:00:00Z", "2026-10-06T05:37:58z", "2026-10-06T05:37:58+02",
            "2026-10-06T05:37:58.123456789012Z", "0001-01-01T00:00:00Z", "2026-1-6T05:37:58Z", "2026-10-06T05:37:58+24:00"
        ]
        for string in lenient {
            XCTAssertEqual(TranscriptTimestamp.parse(string), reference(string), string.debugDescription)
        }
    }

    func testTheHandParserMatchesTheFormatterAcrossGeneratedTimestamps() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            let year = Int.random(in: 1600...2200, using: &generator)
            let month = Int.random(in: 1...12, using: &generator)
            let day = Int.random(in: 1...28, using: &generator)
            var string = String(
                format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day,
                Int.random(in: 0...23, using: &generator), Int.random(in: 0...59, using: &generator), Int.random(in: 0...59, using: &generator)
            )
            // The formatter resolves to milliseconds, so the exact comparison covers up to three digits.
            let fractionDigits = Int.random(in: 0...3, using: &generator)
            if fractionDigits > 0 {
                string += "." + (0..<fractionDigits).map { _ in String(Int.random(in: 0...9, using: &generator)) }.joined()
            }
            switch Int.random(in: 0...3, using: &generator) {
            case 0: string += "Z"
            case 1: string += String(format: "%@%02d:%02d", Bool.random(using: &generator) ? "+" : "-", Int.random(in: 0...23, using: &generator), Int.random(in: 0...59, using: &generator))
            case 2: string += String(format: "%@%02d%02d", Bool.random(using: &generator) ? "+" : "-", Int.random(in: 0...23, using: &generator), Int.random(in: 0...59, using: &generator))
            default: string += "+00:00"
            }
            let expected = try XCTUnwrap(reference(string), string)
            let actual = try XCTUnwrap(TranscriptTimestamp.parse(string), string)
            XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1e-6, string)
        }
    }

    func testEveryDayOfALeapYearAndACenturyYearMatchesTheFormatter() throws {
        for year in [2000, 2024, 1900, 2100] {
            for month in 1...12 {
                for day in 1...31 {
                    let string = String(format: "%04d-%02d-%02dT00:00:00Z", year, month, day)
                    // Days a month lacks are not real dates; both sides must still agree on the result.
                    XCTAssertEqual(TranscriptTimestamp.parse(string), reference(string), string)
                }
            }
        }
    }
}
